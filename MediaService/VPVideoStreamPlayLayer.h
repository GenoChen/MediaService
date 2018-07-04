//
//  VPVideoStreamPlayLayer.h
//  MediaService
//
//  Created by chenjiannan on 2018/7/3.
//  Copyright © 2018年 chenjiannan. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>

@interface VPVideoStreamPlayLayer : CAEAGLLayer

/** 根据frame初始化播放器 */
- (id)initWithFrame:(CGRect)frame;

- (void)inputPixelBuffer:(CVPixelBufferRef)pixelBuffer;


@end
