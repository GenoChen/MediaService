//
//  VEVideoEncoder.h
//  MediaService
//
//  Created by chenjiannan on 2018/6/22.
//  Copyright © 2018年 chenjiannan. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

typedef NS_ENUM(NSUInteger, VEVideoEncoderProfileLevel)
{
    VEVideoEncoderProfileLevelBP,
    VEVideoEncoderProfileLevelMP,
    VEVideoEncoderProfileLevelHP
};

@interface VEVideoEncoderParam : NSObject

/** ProfileLevel 默认为BP */
@property (nonatomic, assign) VEVideoEncoderProfileLevel profileLevel;
/** 编码内容的宽度 */
@property (nonatomic, assign) NSInteger encodeWidth;
/** 编码内容的高度 */
@property (nonatomic, assign) NSInteger encodeHeight;
/** 编码类型 */
@property (nonatomic, assign) CMVideoCodecType encodeType;
/** 码率 单位kbps */
@property (nonatomic, assign) NSInteger bitRate;
/** 帧率 单位为fps，缺省为15fps */
@property (nonatomic, assign) NSInteger frameRate;
/** 最大I帧间隔，单位为秒，缺省为240秒一个I帧 */
@property (nonatomic, assign) NSInteger maxKeyFrameInterval;
/** 是否允许产生B帧 缺省为NO */
@property (nonatomic, assign) BOOL allowFrameReordering;

@end

@protocol VEVideoEncoderDelegate <NSObject>

/**
 编码输出数据

 @param data 输出数据
 @param isKeyFrame 是否为关键帧
 */
- (void)videoEncodeOutputDataCallback:(NSData *)data isKeyFrame:(BOOL)isKeyFrame;

@end

@interface VEVideoEncoder : NSObject

/** 代理 */
@property (nonatomic, weak) id<VEVideoEncoderDelegate> delegate;
/** 编码参数 */
@property (nonatomic, strong) VEVideoEncoderParam *videoEncodeParam;

/**
 初始化方法
 
 @param param 编码参数
 @return 实例
 */
- (instancetype)initWithParam:(VEVideoEncoderParam *)param;

/**
 开始编码
 
 @return 结果
 */
- (BOOL)startVideoEncode;

/**
 停止编码
 
 @return 结果
 */
- (BOOL)stopVideoEncode;

/**
 输入待编码数据
 
 @param sampleBuffer 待编码数据
 @param forceKeyFrame 是否强制I帧
 @return 结果
 */
- (BOOL)videoEncodeInputData:(CMSampleBufferRef)sampleBuffer forceKeyFrame:(BOOL)forceKeyFrame;
/**
 编码过程中调整码率
 
 @param bitRate 码率
 @return 结果
 */
- (BOOL)adjustBitRate:(NSInteger)bitRate;

@end
