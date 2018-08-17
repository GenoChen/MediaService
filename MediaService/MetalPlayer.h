//
//  MetalPlayer.h
//  MediaService
//
//  Created by Geno on 2018/8/15.
//  Copyright © 2018年 chenjiannan. All rights reserved.
//

#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>

@interface MetalPlayer : CAMetalLayer

- (void)adjustSize:(CGSize)size;

- (void)inputPixelBuffer:(CVPixelBufferRef)pixelBuffer;

- (instancetype)initWithFrame:(CGRect)frame;

@end
