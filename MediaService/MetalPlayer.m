//
//  MetalPlayer.m
//  MediaService
//
//  Created by Geno on 2018/8/15.
//  Copyright © 2018年 chenjiannan. All rights reserved.
//

#import "MetalPlayer.h"
@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;
@import AVFoundation;
#import <CoreVideo/CVMetalTextureCache.h>

// The max number of command buffers in flight
static const NSUInteger g_max_inflight_buffers = 3;


float cubeVertexData[16] =
{
    -1.0, -1.0,  0.0, 1.0,
    1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
    1.0,  1.0,  1.0, 0.0,
};

typedef struct {
    matrix_float3x3 matrix;
    vector_float3 offset;
} ColorConversion;


@interface MetalPlayer ()

@end


@implementation MetalPlayer
{

    id <CAMetalDrawable> _currentDrawable;
    BOOL _layerSizeDidUpdate;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    
    // controller
    CADisplayLink *_timer;
    BOOL _gameLoopPaused;
    dispatch_semaphore_t _inflight_semaphore;
    
    // renderer
    id <MTLDevice> _device;
    id <MTLCommandQueue> _commandQueue;
    id <MTLLibrary> _defaultLibrary;
    id <MTLRenderPipelineState> _pipelineState;
    id <MTLBuffer> _vertexBuffer;
    id <MTLDepthStencilState> _depthState;
    id <MTLTexture> _textureY;
    id <MTLTexture> _textureCbCr;
    id <MTLBuffer> _colorConversionBuffer;
    
    CGRect _drawFrame;
    
    CVMetalTextureCacheRef _textureCache;
}


- (void)dealloc
{
    [_timer invalidate];
}


- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super init];
    if (self)
    {
        _inflight_semaphore = dispatch_semaphore_create(g_max_inflight_buffers);
        
        [self _setupMetalWithFrame:frame];
        [self _setupCapture];
        [self _loadAssets];
        
//        _timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(_gameloop)];
//        [_timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    }
    return self;
}



- (void)_setupMetalWithFrame:(CGRect)frame
{
    // Find a usable device
    _device = MTLCreateSystemDefaultDevice();
    
    // Create a new command queue
    _commandQueue = [_device newCommandQueue];
    
    // Load all the shader files with a metal file extension in the project
    _defaultLibrary = [_device newDefaultLibrary];
    
    // Setup metal layer and add as sub layer to view
    self.device = _device;
    self.pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Change this to NO if the compute encoder is used as the last pass on the drawable texture
    self.framebufferOnly = YES;
    
    _drawFrame = frame;
    // Add metal layer to the views layer hierarchy
    [self setFrame:frame];
//
//    self.view.opaque = YES;
//    self.view.backgroundColor = nil;
//    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)_setupCapture
{
    CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textureCache);
    
    ColorConversion colorConversion = {
        // SDTV标准 BT.601 ，YUV转RGB变换矩阵
        .matrix = {
            .columns[0] = { 1.164,  1.164, 1.164, },
            .columns[1] = { 0.000, -0.392, 2.017, },
            .columns[2] = { 1.596, -0.813, 0.000, },
        },
        .offset = { -(16.0/255.0), -0.5, -0.5 },
    };
    
    _colorConversionBuffer = [_device newBufferWithBytes:&colorConversion length:sizeof(colorConversion) options:MTLResourceOptionCPUCacheModeDefault];
    
}

- (void)_loadAssets
{
    // Load the fragment program into the library
    id <MTLFunction> fragmentProgram = [_defaultLibrary newFunctionWithName:@"fragmentColorConversion"];
    
    // Load the vertex program into the library
    id <MTLFunction> vertexProgram = [_defaultLibrary newFunctionWithName:@"vertexPassthrough"];
    
    // Setup the vertex buffers
    _vertexBuffer = [_device newBufferWithBytes:cubeVertexData length:sizeof(cubeVertexData) options:MTLResourceOptionCPUCacheModeDefault];
    _vertexBuffer.label = @"Vertices";
    
    // Create a reusable pipeline state
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.label = @"MyPipeline";
    [pipelineStateDescriptor setSampleCount: 1];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineStateDescriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
    
    NSError* error = NULL;
    _pipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!_pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
    
    MTLDepthStencilDescriptor *depthStateDesc = [[MTLDepthStencilDescriptor alloc] init];
    depthStateDesc.depthCompareFunction = MTLCompareFunctionAlways;
    depthStateDesc.depthWriteEnabled = NO;
    _depthState = [_device newDepthStencilStateWithDescriptor:depthStateDesc];
}

- (void)setupRenderPassDescriptorForTexture:(id <MTLTexture>) texture
{
    if (_renderPassDescriptor == nil)
    {
        _renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    }
    
    _renderPassDescriptor.colorAttachments[0].texture = texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.65f, 0.65f, 0.65f, 1.0f);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
}

- (void)_render
{
    if (_layerSizeDidUpdate)
    {
        CGSize drawableSize = _drawFrame.size;
        self.drawableSize = drawableSize;
        _layerSizeDidUpdate = NO;
    }
    // Create a new command buffer for each renderpass to the current drawable
    id <MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    commandBuffer.label = @"MyCommand";
    
    // obtain a drawable texture for this render pass and set up the renderpass descriptor for the command encoder to render into
    id <CAMetalDrawable> drawable = [self currentDrawable];
    [self setupRenderPassDescriptorForTexture:drawable.texture];
    
    // Create a render command encoder so we can render into something
    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];
    renderEncoder.label = @"MyRenderEncoder";
    [renderEncoder setDepthStencilState:_depthState];
    
    // Set context state
    if(_textureY != nil && _textureCbCr != nil)
    {
        [renderEncoder pushDebugGroup:@"DrawCube"];
        [renderEncoder setRenderPipelineState:_pipelineState];
        [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];
        [renderEncoder setFragmentTexture:_textureY atIndex:0];
        [renderEncoder setFragmentTexture:_textureCbCr atIndex:1];
        [renderEncoder setFragmentBuffer:_colorConversionBuffer offset:0 atIndex:0];
        
        // Tell the render context we want to draw our primitives
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:1];
        [renderEncoder popDebugGroup];
    }
    
    // We're done encoding commands
    [renderEncoder endEncoding];
    
    // Schedule a present once the framebuffer is complete
    [commandBuffer presentDrawable:drawable];
    
    // Finalize rendering here & push the command buffer to the GPU
    [commandBuffer commit];
    _currentDrawable = nil;
}

- (void)adjustFrame:(CGRect)frame
{
    _drawFrame = frame;
    _layerSizeDidUpdate = YES;
    [self setFrame:frame];
}


#pragma mark Utilities

- (id <CAMetalDrawable>)currentDrawable
{
    while (_currentDrawable == nil)
    {
        _currentDrawable = [self nextDrawable];
        if (!_currentDrawable)
        {
            NSLog(@"CurrentDrawable is nil");
        }
    }
    return _currentDrawable;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate
- (void)inputPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    id<MTLTexture> textureY = nil;
    id<MTLTexture> textureCbCr = nil;
    
    // textureY
    {
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        MTLPixelFormat pixelFormat = MTLPixelFormatR8Unorm;
        
        CVMetalTextureRef texture = NULL;
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, pixelBuffer, NULL, pixelFormat, width, height, 0, &texture);
        if(status == kCVReturnSuccess)
        {
            textureY = CVMetalTextureGetTexture(texture);
            CFRelease(texture);
        }
    }
    
    // textureCbCr
    {
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);
        MTLPixelFormat pixelFormat = MTLPixelFormatRG8Unorm;
        
        CVMetalTextureRef texture = NULL;
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, _textureCache, pixelBuffer, NULL, pixelFormat, width, height, 1, &texture);
        if(status == kCVReturnSuccess)
        {
            textureCbCr = CVMetalTextureGetTexture(texture);
            CFRelease(texture);
        }
    }
    
    if(textureY != nil && textureCbCr != nil)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            // always assign the textures atomic
            self->_textureY = textureY;
            self->_textureCbCr = textureCbCr;
            [self _render];
            
        });
    }
}



@end
