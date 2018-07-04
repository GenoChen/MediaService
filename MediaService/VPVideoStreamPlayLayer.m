//
//  VPVideoStreamPlayLayer.m
//  MediaService
//
//  Created by chenjiannan on 2018/7/3.
//  Copyright © 2018年 chenjiannan. All rights reserved.
//

#import "VPVideoStreamPlayLayer.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

// Uniform index.
enum
{
    UNIFORM_Y,
    UNIFORM_UV,
    UNIFORM_ROTATION_ANGLE,
    UNIFORM_COLOR_CONVERSION_MATRIX,
    NUM_UNIFORMS
};
GLint uniforms[NUM_UNIFORMS];

// Attribute index.
enum
{
    ATTRIB_VERTEX,
    ATTRIB_TEXCOORD,
    NUM_ATTRIBUTES
};

// SDTV标准 BT.601 ，YUV转RGB变换矩阵
static const GLfloat kColorConversion601[] = {
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
};

// HDTV标准 BT.709，YUV转RGB变换矩阵
static const GLfloat kColorConversion709[] = {
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
};


const GLchar *shader_fsh = (const GLchar*)"varying highp vec2 texCoordVarying;"
"precision mediump float;"
"uniform sampler2D SamplerY;"
"uniform sampler2D SamplerUV;"
"uniform mat3 colorConversionMatrix;"
"void main()"
"{"
"    mediump vec3 yuv;"
"    lowp vec3 rgb;"
"    yuv.x = (texture2D(SamplerY, texCoordVarying).r - (16.0/255.0));"
"    yuv.yz = (texture2D(SamplerUV, texCoordVarying).rg - vec2(0.5, 0.5));"
"    rgb = colorConversionMatrix * yuv;"
"    gl_FragColor = vec4(rgb, 1);"
"}";

const GLchar *shader_vsh = (const GLchar*)"attribute vec4 position;"
"attribute vec2 texCoord;"
"uniform float preferredRotation;"
"varying vec2 texCoordVarying;"
"void main()"
"{"
"    mat4 rotationMatrix = mat4(cos(preferredRotation), -sin(preferredRotation), 0.0, 0.0,"
"                               sin(preferredRotation),  cos(preferredRotation), 0.0, 0.0,"
"                               0.0,                        0.0, 1.0, 0.0,"
"                               0.0,                        0.0, 0.0, 1.0);"
"    gl_Position = position * rotationMatrix;"
"    texCoordVarying = texCoord;"
"}";


@interface VPVideoStreamPlayLayer ()
{
    // layer的像素尺寸
    GLint _backingWidth;
    GLint _backingHeight;
    
    // 上下文对象
    EAGLContext *_context;
    
    // 亮度纹理引用
    CVOpenGLESTextureRef _luminanceTextureRef;
    // 色度纹理引用
    CVOpenGLESTextureRef _chrominanceTextureRef;
    // 纹理缓存引用
    CVOpenGLESTextureCacheRef _videoTextureCacheRef;
    
    // 两个buffer的引用
    GLuint _frameBufferHandle;
    GLuint _colorBufferHandle;
}

/** 着色器 */
@property (nonatomic, assign) GLuint program;
/** 输入的数据 */
@property (nonatomic, assign) CVPixelBufferRef pixelBuffer;

@end


@implementation VPVideoStreamPlayLayer

/**
 输入数据进行播放

 @param pixelBuffer 输入数据
 */
- (void)inputPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if(pixelBuffer)
    {
        CVPixelBufferRelease(pixelBuffer);
    }
    self.pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    
    [self displayPixelBuffer:self.pixelBuffer];
}

/**
 初始化方法

 @param frame 控件尺寸
 @return 实例
 */
- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super init];
    if (self)
    {
        self.frame = frame;
        
        // 设置像素比例，也就是iOS的原图、@2x、@3x像素密度是按倍数渲染的
        self.contentsScale = [[UIScreen mainScreen] scale];
        // 默认是透明的，透明的性能不好，设置为不透明
        self.opaque = YES;
        
        // 设置描绘属性，设置不缓存渲染内容
        /*
         kEAGLDrawablePropertyRetainedBacking设置是否需要保留已经绘制到图层上面的内容，用NSNumber来包装，
         为FALSE，表示不想保持呈现的内容，因此在下一次呈现时，应用程序必须完全重绘一次。将该设置为 TRUE 对性能和资源影像较大，因此只有当renderbuffer需要保持其内容不变时，我们才设置 kEAGLDrawablePropertyRetainedBacking  为 TRUE。
         kEAGLDrawablePropertyColorFormat 设置绘制对象内部的颜色缓冲区的格式 32位的RGBA的形式
         包含的格式
         kEAGLColorFormatRGBA8; 32位RGBA的颜色 4x8=32
         kEAGLColorFormatRGB565; 16位的RGB的颜色
         kEAGLColorFormatSRGBA8 SRGB
         */
        self.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking :@(FALSE), kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8};
        
        
        // 根据API版本创建上下文
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        if (!_context || ![EAGLContext setCurrentContext:_context])
        {
            return nil;
        }
        
        /**
         buffer分为FrameBuffer和Render Buffer 两大类
         frameBuffer(FBO)相当于renderBuffer的管理者
         renderBuffer分为3类，一个是colorBuffer，depthBuffer,stencilBuffer, 这里用的是colorBuffer
         */
        [self setupRenderBuffer];
        [self setupFrameBuffer];
        
        [self loadShaders];
    }
    
    return self;
}

/**
 绘制图像

 @param pixelBuffer 输入数据
 */
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!_context || ![EAGLContext setCurrentContext:_context])
    {
        return;
    }
    if(pixelBuffer == NULL)
    {
        NSLog(@"Pixel buffer is null");
        return;
    }
    // 清空纹理
    [self cleanUpTextures];
    
    // 创建纹理对象
    [self setupTexture:pixelBuffer];
    
    // YUV 转 RGB
    [self convertYUVToRGB:pixelBuffer];
    
    // 设置绘制窗口
    glViewport(0, 0, _backingWidth, _backingHeight);
    
    // 把上下文的东西渲染到屏幕上
    [_context presentRenderbuffer:GL_RENDERBUFFER];
    
    //    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    //    glClear(GL_COLOR_BUFFER_BIT);
}

/**
 清空纹理
 */
- (void)cleanUpTextures
{
    // 清空亮度引用
    if (_luminanceTextureRef)
    {
        CFRelease(_luminanceTextureRef);
        _luminanceTextureRef = NULL;
    }
    
    // 清空色度引用
    if (_chrominanceTextureRef)
    {
        CFRelease(_chrominanceTextureRef);
        _chrominanceTextureRef = NULL;
    }
    
    // 清空纹理缓存
    CVOpenGLESTextureCacheFlush(_videoTextureCacheRef, 0);
    if(_videoTextureCacheRef)
    {
        CFRelease(_videoTextureCacheRef);
    }
}

/**
 设置纹理

 @param pixelBuffer 数据
 */
- (void)setupTexture:(CVPixelBufferRef)pixelBuffer
{
    // 获取视频数据中的宽高
    CGFloat frameWidth = CVPixelBufferGetWidth(pixelBuffer);
    CGFloat frameHeight = CVPixelBufferGetHeight(pixelBuffer);
    
    // 创建纹理对象
    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_videoTextureCacheRef);
    if (err != noErr)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
        return;
    }
    // 启用纹理缓冲区0
    glActiveTexture(GL_TEXTURE0);
    // 创建亮度纹理，也就是YUV数据的Y分量
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _videoTextureCacheRef, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RED_EXT, frameWidth, frameHeight, GL_RED_EXT, GL_UNSIGNED_BYTE, 0, &_luminanceTextureRef);
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    // 绑定到文理缓冲区
    glBindTexture(CVOpenGLESTextureGetTarget(_luminanceTextureRef), CVOpenGLESTextureGetName(_luminanceTextureRef));
    // 设置纹理滤波
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    // 激活纹理缓冲区1
    glActiveTexture(GL_TEXTURE1);
    // UV分量数据
    err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _videoTextureCacheRef, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RG_EXT, frameWidth / 2, frameHeight / 2, GL_RG_EXT, GL_UNSIGNED_BYTE, 1, &_chrominanceTextureRef);
    if (err)
    {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }
    // 绑定到文理缓冲区
    glBindTexture(CVOpenGLESTextureGetTarget(_chrominanceTextureRef), CVOpenGLESTextureGetName(_chrominanceTextureRef));
    // 设置纹理滤波
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
}

/**
 YUV转RGB

 @param pixelBuffer 输入数据
 */
- (void)convertYUVToRGB:(CVPixelBufferRef)pixelBuffer
{
    // 获取视频数据格式
    CFTypeRef colorAttachments = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, NULL);
    // 判断视频格式
    const GLfloat *preferredConversion;
    if (CFStringCompare(colorAttachments, kCVImageBufferYCbCrMatrix_ITU_R_601_4, 0) == kCFCompareEqualTo)
    {
        preferredConversion = kColorConversion601;
    }
    else
    {
        preferredConversion = kColorConversion709;
    }
    // 在创建纹理之前，有激活过纹理单元，就是那个数字.GL_TEXTURE0,GL_TEXTURE1
    // 指定着色器中亮度纹理对应哪一层纹理单元
    // 这样就会把亮度纹理，往着色器上贴
    glUniform1i(uniforms[UNIFORM_Y], 0);
    glUniform1i(uniforms[UNIFORM_UV], 1);
    glUniform1f(uniforms[UNIFORM_ROTATION_ANGLE], 0);
    // YUV转RGB矩阵
    glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, GL_FALSE, preferredConversion);
    
    // 固定宽高比缩放到当前layer的尺寸
    CGRect viewBounds = self.bounds;
    // 获取视频数据中的宽高
    CGFloat frameWidth = CVPixelBufferGetWidth(pixelBuffer);
    CGFloat frameHeight = CVPixelBufferGetHeight(pixelBuffer);
    CGSize contentSize = CGSizeMake(frameWidth, frameHeight);
    // 把图像画面的尺寸等比例缩放到当前视图的尺寸
    CGRect vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(contentSize, viewBounds);
    
    // 计算一下图像画面缩放后哪个边没填充满。例如画面尺寸是(180,320)，layer的尺寸是(200,320)，那么下面计算出来应该是(0.9,1)
    CGSize normalizedSamplingSize = CGSizeMake(0.0, 0.0);
    CGSize cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width / viewBounds.size.width,
                                        vertexSamplingRect.size.height / viewBounds.size.height);
    
    // 哪个边大就哪个边填充整个layer
    if (cropScaleAmount.width > cropScaleAmount.height)
    {
        normalizedSamplingSize.width = 1.0;
        normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width;
    }
    else
    {
        normalizedSamplingSize.width = cropScaleAmount.width/cropScaleAmount.height;
        normalizedSamplingSize.height = 1.0;;
    }
    
    // 确定顶点数据结构
    GLfloat quadVertexData [] = {
        -1 * normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
        normalizedSamplingSize.width, -1 * normalizedSamplingSize.height,
        -1 * normalizedSamplingSize.width, normalizedSamplingSize.height,
        normalizedSamplingSize.width, normalizedSamplingSize.height,
    };
    
    /** 设置顶点着色器属性
     参数indx：属性ID，给哪个属性描述信息
     参数size：顶点属性由几个值组成，这个值必须位1，2，3或4；
     参数type：表示属性的数据类型
     参数normalized:GL_FALSE表示不要将数据类型标准化
     参数stride 表示数组中每个元素的长度；
     参数ptr 表示数组的首地址
     */
    glVertexAttribPointer(ATTRIB_VERTEX, 2, GL_FLOAT, 0, 0, quadVertexData);
    // 激活ATTRIB_VERTEX顶点数组
    glEnableVertexAttribArray(ATTRIB_VERTEX);
    
    // 确定纹理数据结构
    CGRect textureSamplingRect = CGRectMake(0, 0, 1, 1);
    GLfloat quadTextureData[] =  {
        CGRectGetMinX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        CGRectGetMaxX(textureSamplingRect), CGRectGetMaxY(textureSamplingRect),
        CGRectGetMinX(textureSamplingRect), CGRectGetMinY(textureSamplingRect),
        CGRectGetMaxX(textureSamplingRect), CGRectGetMinY(textureSamplingRect)
    };
    
    // 设置顶点着色器属性
    glVertexAttribPointer(ATTRIB_TEXCOORD, 2, GL_FLOAT, 0, 0, quadTextureData);
    // 激活ATTRIB_TEXCOORD顶点数组
    glEnableVertexAttribArray(ATTRIB_TEXCOORD);
    // 渲染纹理数据
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}


/**
 初始化 RenderBuffer
 */
- (void)setupRenderBuffer
{
    // 清理缓存区
    if (_colorBufferHandle)
    {
        glDeleteBuffers(1, &_colorBufferHandle);
        _colorBufferHandle = 0;
    }
    // 申请一个缓冲区
    glGenRenderbuffers(1, &_colorBufferHandle);
    // 将缓冲区绑定到指定的空间中，把colorRenderbuffer绑定在OpenGL ES的渲染缓存GL_RENDERBUFFER上
    glBindRenderbuffer(GL_RENDERBUFFER, _colorBufferHandle);
    // 通过调用上下文的renderbufferStorage:fromDrawable:方法并传递层对象作为参数来分配其存储空间。宽度，高度和像素格式取自层，用于为renderbuffer分配存储空间
    [_context renderbufferStorage:GL_RENDERBUFFER fromDrawable:self];
    
    // 获取渲染缓存对象的宽高属性，获取到的实际上就是当前layer尺寸 * 像素倍数(@2x、@3x)
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &_backingWidth);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &_backingHeight);
}

/**
 初始化 FrameBuffer
 */
-(void)setupFrameBuffer
{
    // 清理缓存区
    if (_frameBufferHandle)
    {
        glDeleteBuffers(1, &_frameBufferHandle);
        _frameBufferHandle = 0;
    }
    // 申请一个缓存区句柄
    glGenFramebuffers(1, &_frameBufferHandle);
    //4、将缓冲区绑定到指定的空间中
    glBindFramebuffer(GL_FRAMEBUFFER, _frameBufferHandle);
    //5、把GL_RENDERBUFFER里的colorRenderbuffer附在GL_FRAMEBUFFER的GL_COLOR_ATTACHMENT0（颜色附着点0）上
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, _colorBufferHandle);
    GLenum bufferStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (bufferStatus != GL_FRAMEBUFFER_COMPLETE)
    {
        NSLog(@"Failed to make complete framebuffer object %x", bufferStatus);
    }
}

/**
 加载着色器

 @return 结果
 */
- (BOOL)loadShaders
{
    GLuint vertShader = 0;
    GLuint fragShader = 0;
    // 清理缓存
    if (self.program)
    {
        glValidateProgram(self.program);
    }
    // 创建着色器程序
    self.program = glCreateProgram();
    
    if(![self compileShaderString:&vertShader type:GL_VERTEX_SHADER shaderString:shader_vsh])
    {
        NSLog(@"Failed to compile vertex shader");
        return NO;
    }
    
    if(![self compileShaderString:&fragShader type:GL_FRAGMENT_SHADER shaderString:shader_fsh])
    {
        NSLog(@"Failed to compile fragment shader");
        return NO;
    }
    
    // 绑定着色器
    // 绑定顶点着色器
    glAttachShader(self.program, vertShader);
    // 绑定片段着色器
    glAttachShader(self.program, fragShader);
    
    // 绑定着色器属性,方便以后获取，以后根据角标获取，要在链接前进行绑定，否则会获取不到
    glBindAttribLocation(self.program, ATTRIB_VERTEX, "position");
    glBindAttribLocation(self.program, ATTRIB_TEXCOORD, "texCoord");
    
    // 链接着色器程序
    glLinkProgram(self.program);
    
    // 获取链接结果，失败了释放内存
    GLint status;
    glGetProgramiv(self.program, GL_LINK_STATUS, &status);
    if (status == 0)
    {
        NSLog(@"Failed to link program: %d", self.program);
        if (vertShader)
        {
            glDeleteShader(vertShader);
            vertShader = 0;
        }
        if (fragShader)
        {
            glDeleteShader(fragShader);
            fragShader = 0;
        }
        if (self.program)
        {
            glDeleteProgram(self.program);
            self.program = 0;
        }
        return NO;
    }
    
    // 获取全局参数，一定要在链接完成后才行，否则拿不到
    uniforms[UNIFORM_Y] = glGetUniformLocation(self.program, "SamplerY");
    uniforms[UNIFORM_UV] = glGetUniformLocation(self.program, "SamplerUV");
    uniforms[UNIFORM_ROTATION_ANGLE] = glGetUniformLocation(self.program, "preferredRotation");
    uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = glGetUniformLocation(self.program, "colorConversionMatrix");
    
    // 两个着色器都已经绑定到着色器程序上了，卸磨杀猪
    if (vertShader)
    {
        glDetachShader(self.program, vertShader);
        glDeleteShader(vertShader);
    }
    if (fragShader)
    {
        glDetachShader(self.program, fragShader);
        glDeleteShader(fragShader);
    }
    // 启动着色器程序
    glUseProgram(self.program);
    
    return YES;
}

/**
 创建着色器

 @param shader 着色器
 @param type 类型 顶点着色器：GL_VERTEX_SHADER   片段着色器：GL_FRAGMENT_SHADER
 @param shaderString 着色器源码
 @return 结果
 */
- (BOOL)compileShaderString:(GLuint *)shader type:(GLenum)type shaderString:(const GLchar*)shaderString
{
    // 创建着色器
    *shader = glCreateShader(type);
    // 加载着色器源码
    glShaderSource(*shader, 1, &shaderString, NULL);
    // 编译着色器
    glCompileShader(*shader);
    // 获取结果，没获取到就释放内存
    GLint status = 0;
    glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
    if (status == 0)
    {
        glDeleteShader(*shader);
        return NO;
    }
    return YES;
}

/**
 创建着色器

 @param shader 着色器
 @param type 类型 顶点着色器：GL_VERTEX_SHADER   片段着色器：GL_FRAGMENT_SHADER
 @param URL 着色器源码路径
 @return 结果
 */
- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type URL:(NSURL *)URL
{
    NSError *error;
    NSString *sourceString = [[NSString alloc] initWithContentsOfURL:URL encoding:NSUTF8StringEncoding error:&error];
    if (sourceString == nil) {
        NSLog(@"Failed to load vertex shader: %@", [error localizedDescription]);
        return NO;
    }
    
    const GLchar *source = (GLchar *)[sourceString UTF8String];
    return [self compileShaderString:shader type:type shaderString:source];
}


- (void)dealloc
{
    if (!_context || ![EAGLContext setCurrentContext:_context])
    {
        return;
    }
    
    [self cleanUpTextures];
    
    if(self.pixelBuffer)
    {
        CVPixelBufferRelease(self.pixelBuffer);
    }
    
    if (self.program)
    {
        glDeleteProgram(self.program);
        self.program = 0;
    }
    if(_context)
    {
        _context = nil;
    }
}

@end
