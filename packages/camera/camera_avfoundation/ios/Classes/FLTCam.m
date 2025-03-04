// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTCam.h"
#import "FLTCam_Test.h"
#import "FLTSavePhotoDelegate.h"
#import "QueueUtils.h"

@import CoreMotion;
@import CoreLocation;
#import <libkern/OSAtomic.h>

@implementation FLTImageStreamHandler

- (instancetype)initWithCaptureSessionQueue:(dispatch_queue_t)captureSessionQueue {
	self = [super init];
	NSAssert(self, @"super init cannot be nil");
	_captureSessionQueue = captureSessionQueue;
	return self;
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.captureSessionQueue, ^{
		weakSelf.eventSink = nil;
	});
	return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
									   eventSink:(nonnull FlutterEventSink)events {
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.captureSessionQueue, ^{
		weakSelf.eventSink = events;
	});
	return nil;
}
@end

@interface FLTCam () <AVCaptureVideoDataOutputSampleBufferDelegate,
AVCaptureAudioDataOutputSampleBufferDelegate>

@property(readonly, nonatomic) int64_t textureId;
@property BOOL enableAudio;
@property(nonatomic) FLTImageStreamHandler *imageStreamHandler;
@property(readonly, nonatomic) AVCaptureSession *videoCaptureSession;
@property(readonly, nonatomic) AVCaptureSession *audioCaptureSession;

@property(readonly, nonatomic) AVCaptureInput *captureVideoInput;
/// Tracks the latest pixel buffer sent from AVFoundation's sample buffer delegate callback.
/// Used to deliver the latest pixel buffer to the flutter engine via the `copyPixelBuffer` API.
@property(readwrite, nonatomic) CVPixelBufferRef latestPixelBuffer;
@property(readonly, nonatomic) CGSize captureSize;
@property(strong, nonatomic) AVAssetWriter *videoWriter;
@property(strong, nonatomic) AVAssetWriterInput *videoWriterInput;
@property(strong, nonatomic) AVAssetWriterInput *audioWriterInput;
@property(strong, nonatomic) AVAssetWriterInputPixelBufferAdaptor *assetWriterPixelBufferAdaptor;
@property(strong, nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property(strong, nonatomic) AVCaptureAudioDataOutput *audioOutput;
@property(strong, nonatomic) NSString *videoRecordingPath;
@property(assign, nonatomic) BOOL isRecording;
@property(assign, nonatomic) BOOL isRecordingPaused;
@property(assign, nonatomic) BOOL videoIsDisconnected;
@property(assign, nonatomic) BOOL audioIsDisconnected;
@property(assign, nonatomic) BOOL isAudioSetup;

/// Number of frames currently pending processing.
@property(assign, nonatomic) int streamingPendingFramesCount;

/// Maximum number of frames pending processing.
@property(assign, nonatomic) int maxStreamingPendingFramesCount;

@property(assign, nonatomic) UIDeviceOrientation lockedCaptureOrientation;
@property(assign, nonatomic) CMTime lastVideoSampleTime;
@property(assign, nonatomic) CMTime lastAudioSampleTime;
@property(assign, nonatomic) CMTime videoTimeOffset;
@property(assign, nonatomic) CMTime audioTimeOffset;
@property(nonatomic) CMMotionManager *motionManager;
@property(assign, nonatomic) CLLocationManager *locationManager;
@property AVAssetWriterInputPixelBufferAdaptor *videoAdaptor;
/// All FLTCam's state access and capture session related operations should be on run on this queue.
@property(strong, nonatomic) dispatch_queue_t captureSessionQueue;
/// The queue on which `latestPixelBuffer` property is accessed.
/// To avoid unnecessary contention, do not access `latestPixelBuffer` on the `captureSessionQueue`.
@property(strong, nonatomic) dispatch_queue_t pixelBufferSynchronizationQueue;
/// The queue on which captured photos (not videos) are written to disk.
/// Videos are written to disk by `videoAdaptor` on an internal queue managed by AVFoundation.
@property(strong, nonatomic) dispatch_queue_t photoIOQueue;
@property(assign, nonatomic) UIDeviceOrientation deviceOrientation;
@end

@implementation FLTCam

NSString *const errorMethod = @"error";

- (instancetype)initWithCameraName:(NSString *)cameraName
				  resolutionPreset:(NSString *)resolutionPreset
					   enableAudio:(BOOL)enableAudio
					   orientation:(UIDeviceOrientation)orientation
			   captureSessionQueue:(dispatch_queue_t)captureSessionQueue
				   locationManager:(CLLocationManager *)locationManager
				   	 motionManager:(CMMotionManager *)motionManager
							 error:(NSError **)error {
	return [self initWithCameraName:cameraName
				   resolutionPreset:resolutionPreset
						enableAudio:enableAudio
						orientation:orientation
				videoCaptureSession:[[AVCaptureSession alloc] init]
				audioCaptureSession:[[AVCaptureSession alloc] init]
				captureSessionQueue:captureSessionQueue
					locationManager:(CLLocationManager *)locationManager
					  motionManager:(CMMotionManager *)motionManager
							  error:error];
}

- (instancetype)initWithCameraName:(NSString *)cameraName
				  resolutionPreset:(NSString *)resolutionPreset
					   enableAudio:(BOOL)enableAudio
					   orientation:(UIDeviceOrientation)orientation
			   videoCaptureSession:(AVCaptureSession *)videoCaptureSession
			   audioCaptureSession:(AVCaptureSession *)audioCaptureSession
			   captureSessionQueue:(dispatch_queue_t)captureSessionQueue
				   locationManager:(CLLocationManager *)locationManager
				   	 motionManager:(CMMotionManager *)motionManager
							 error:(NSError **)error {
	self = [super init];
	NSAssert(self, @"super init cannot be nil");
	@try {
		_resolutionPreset = FLTGetFLTResolutionPresetForString(resolutionPreset);
	} @catch (NSError *e) {
		*error = e;
	}
	_enableAudio = enableAudio;
	_captureSessionQueue = captureSessionQueue;
	_pixelBufferSynchronizationQueue =
	dispatch_queue_create("io.flutter.camera.pixelBufferSynchronizationQueue", NULL);
	_photoIOQueue = dispatch_queue_create("io.flutter.camera.photoIOQueue", NULL);
	_videoCaptureSession = videoCaptureSession;
	_audioCaptureSession = audioCaptureSession;
	_captureDevice = [AVCaptureDevice deviceWithUniqueID:cameraName];
	_flashMode = _captureDevice.hasFlash ? FLTFlashModeAuto : FLTFlashModeOff;
	_exposureMode = FLTExposureModeAuto;
	_focusMode = FLTFocusModeAuto;
	_lockedCaptureOrientation = UIDeviceOrientationUnknown;
	_deviceOrientation = orientation;
	_videoFormat = kCVPixelFormatType_32BGRA;
	_inProgressSavePhotoDelegates = [NSMutableDictionary dictionary];
	_locationManager = locationManager;
	_motionManager = motionManager;

	// To limit memory consumption, limit the number of frames pending processing.
	// After some testing, 4 was determined to be the best maximum value.
	// https://github.com/flutter/plugins/pull/4520#discussion_r766335637
	_maxStreamingPendingFramesCount = 4;

	NSError *localError = nil;
	AVCaptureConnection *connection = [self createConnection:&localError];
	if (localError) {
		*error = localError;
		return nil;
	}

	[_videoCaptureSession addInputWithNoConnections:_captureVideoInput];
	[_videoCaptureSession addOutputWithNoConnections:_captureVideoOutput];
	[_videoCaptureSession addConnection:connection];

	_capturePhotoOutput = [AVCapturePhotoOutput new];
	[_capturePhotoOutput setHighResolutionCaptureEnabled:YES];
	[_capturePhotoOutput setDepthDataDeliveryEnabled:_capturePhotoOutput.depthDataDeliverySupported];

	NSArray* depthFormats = [_captureDevice.activeFormat supportedDepthDataFormats];

	CMVideoDimensions bestDepthDims = { .width = 0, .height = 0 };
	AVCaptureDeviceFormat *bestDepthFormat = nil;
	for( AVCaptureDeviceFormat *format in depthFormats ) {
		FourCharCode pixelFormatType = CMFormatDescriptionGetMediaSubType(format.formatDescription);
		CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription);

		if( pixelFormatType == kCVPixelFormatType_DepthFloat16)
		{
			if( dims.width >= bestDepthDims.width || dims.height >= bestDepthDims.height )
			{
				bestDepthFormat = format;
//				NSLog(@"Camera.BestDepthFormat => %@, %u,%u",bestDepthFormat,dims.width,dims.height);
			}
		}
	}

	// kCVPixelFormatType_DepthFloat16 = hdep
	// kCVPixelFormatType_DepthFloat32 = fdep
	// kCVPixelFormatType_DisparityFloat16 = hdis
	// kCVPixelFormatType_DisparityFloat32 = fdis

	// fov=62.331, 320x180 - 1x Lidar
	// fov:73.292, 640x360 - 1x TrueDepth
	// fov=37.784, 320x180 - 1x Dual
	// fov=70.291, 320x180 - 0.5x Dual

	// set the depth data format to the max possible quality
	if( bestDepthFormat != nil ) {
		[_captureDevice lockForConfiguration:nil];
		// NSLog(@"Setting Camera.ActiveDepthFormat      => %@",bestDepthFormat);
		[_captureDevice setActiveDepthDataFormat:bestDepthFormat];
		[_captureDevice unlockForConfiguration];
	}

	// NSLog(@"Camera.PhotoOutput       => %@ [%@]",self.capturePhotoOutput,_captureDevice);
	// NSLog(@"Camera.ActiveFormat      => %@",_captureDevice.activeFormat);
	// NSLog(@"Camera.ActiveDepthFormat => %@",_captureDevice.activeDepthDataFormat);
	// NSLog(@"Camera.DepthFormats      => %@", depthFormats);

	[_videoCaptureSession addOutput:_capturePhotoOutput];

	// CLLocation *location = [_locationManager location];
	// NSLog(@"Camera.InitLocation      => %@      Location: %@",_locationManager, location);

	// _motionManager = [[CMMotionManager alloc] init];
	[_motionManager startAccelerometerUpdates];
	[_motionManager startGyroUpdates];
	[_motionManager startDeviceMotionUpdates];
	[_motionManager startMagnetometerUpdates];

	// NSLog(@"Camera: MotionManager => %@",_motionManager);
	// NSLog(@"Camera: MotionManager => %@",_motionManager.accelerometerData);
	// NSLog(@"Camera: MotionManager Motion Active => %@",_motionManager.isDeviceMotionActive ? @"Y":@"N");
	// NSLog(@"Camera: MotionManager Accel Active => %@",_motionManager.isAccelerometerActive ? @"Y":@"N");
	// NSLog(@"Camera: MotionManager Gyro Active => %@",_motionManager.isGyroActive ? @"Y":@"N");
	// NSLog(@"Camera: MotionManager Magno Active => %@",_motionManager.isMagnetometerActive ? @"Y":@"N");

	// if ( _motionManager.isDeviceMotionActive ) {
	// 	NSLog(@"Camera: Motion = %@",_motionManager.deviceMotion);
	// }
	// if ( _motionManager.isAccelerometerActive ) {
	// 	NSLog(@"Camera: Accel = %@",_motionManager.accelerometerData);
	// }

	// if ( _motionManager.isGyroActive ) {
	// 	NSLog(@"Camera: Gryo = %@",_motionManager.gyroData);
	// }

	// if ( _motionManager.isMagnetometerActive ) {
	// 	NSLog(@ "Camera: Magno = %@",_motionManager.magnetometerData);
	// }

	[self setCaptureSessionPreset:_resolutionPreset];
	[self updateOrientation];

	[self setZoomLevel:[self getMinAvailableZoomFactor]];

	return self;
}

- (AVCaptureConnection *)createConnection:(NSError **)error {
	// Setup video capture input.
	_captureVideoInput = [AVCaptureDeviceInput deviceInputWithDevice:_captureDevice error:error];

	if (*error) {
		return nil;
	}

	// Setup video capture output.
	_captureVideoOutput = [AVCaptureVideoDataOutput new];
	_captureVideoOutput.videoSettings =
	@{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(_videoFormat)};
	[_captureVideoOutput setAlwaysDiscardsLateVideoFrames:YES];
	[_captureVideoOutput setSampleBufferDelegate:self queue:_captureSessionQueue];

	// Setup video capture connection.
	AVCaptureConnection *connection =
	[AVCaptureConnection connectionWithInputPorts:_captureVideoInput.ports
										   output:_captureVideoOutput];
	if ([_captureDevice position] == AVCaptureDevicePositionFront) {
		connection.videoMirrored = YES;
	}

	return connection;
}

- (void)start {
	[_videoCaptureSession startRunning];
	[_audioCaptureSession startRunning];
}

- (void)stop {
	[_videoCaptureSession stopRunning];
	[_audioCaptureSession stopRunning];
}

- (void)setVideoFormat:(OSType)videoFormat {
	_videoFormat = videoFormat;
	_captureVideoOutput.videoSettings =
	@{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(videoFormat)};
}

- (void)setDeviceOrientation:(UIDeviceOrientation)orientation {
	if (_deviceOrientation == orientation) {
		return;
	}

	_deviceOrientation = orientation;
	[self updateOrientation];
}

- (void)updateOrientation {
	if (_isRecording) {
		return;
	}

	UIDeviceOrientation orientation = (_lockedCaptureOrientation != UIDeviceOrientationUnknown)
	? _lockedCaptureOrientation
	: _deviceOrientation;

	[self updateOrientation:orientation forCaptureOutput:_capturePhotoOutput];
	[self updateOrientation:orientation forCaptureOutput:_captureVideoOutput];
}

- (void)updateOrientation:(UIDeviceOrientation)orientation
		 forCaptureOutput:(AVCaptureOutput *)captureOutput {
	if (!captureOutput) {
		return;
	}

	AVCaptureConnection *connection = [captureOutput connectionWithMediaType:AVMediaTypeVideo];
	if (connection && connection.isVideoOrientationSupported) {
		connection.videoOrientation = [self getVideoOrientationForDeviceOrientation:orientation];
	}
}

- (NSDictionary *)sanitizeDictionary:(NSDictionary *)dict
{
	NSMutableDictionary *mutableDict = [dict mutableCopy];

	for( id key in dict )
	{
		id obj = dict[key];
		if ( [obj isKindOfClass:[NSData class]] )
		{
			mutableDict[key] = [obj base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength];
			// NSLog(@"key: %@  newValue:%@",key,mutableDict[key]);
		}
		else if ( [obj isKindOfClass:[NSDictionary class]] )
		{
			mutableDict[key] = [self sanitizeDictionary:obj];
		}
	}

	return mutableDict;
}

- (NSData *)convertCVPixelBufferToNSData:(CVPixelBufferRef)pixelBuffer {
	CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

	int bufferWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
	int bufferHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
	size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

	uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
	size_t size = bytesPerRow * bufferHeight;
	NSData *data = [NSData dataWithBytes:baseAddress length:size];

	CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

	return data;
}

- (void)captureToFile:(FLTThreadSafeFlutterResult *)result {

	// Set capture file type
	AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettingsWithFormat:@{
		(NSString *)AVVideoCodecKey : AVVideoCodecTypeHEVC
		// (NSString *)AVVideoCodecKey : AVVideoCodecTypeJPEG // JPEG strips the GPS data
	}];

	if (_resolutionPreset == FLTResolutionPresetMax) {
		[settings setHighResolutionPhotoEnabled:YES];
	}

	// Enable depth data delivery if it is supported.
	[settings setDepthDataDeliveryEnabled:self.capturePhotoOutput.depthDataDeliverySupported];

	// Embed depth data if it is supported and photo output is configured to deliver it.
	// libHeif doesn't currently support unfiltered depth data, so we won't embed it.
	[settings setEmbedsDepthDataInPhoto:NO];

	// Don't smooth depth data, bad for computer vision. No, no, bad algo, sit! Good boy.
	// This also breaks libheif currently.  It can't handle NaNs in the depth data.
	[settings setDepthDataFiltered:NO];


	AVCaptureFlashMode avFlashMode = FLTGetAVCaptureFlashModeForFLTFlashMode(_flashMode);
	if (avFlashMode != -1) {
		[settings setFlashMode:avFlashMode];
	}

	NSError *error;
	NSString *path = [self getTemporaryFilePathWithExtension:@"heic"
												   subfolder:@"pictures"
													  prefix:@"CAP_"
													   error:error];
	if (error) {
		[result sendError:error];
		return;
	}

	__weak typeof(self) weakSelf = self;
	FLTSavePhotoDelegate *savePhotoDelegate = [[FLTSavePhotoDelegate alloc]
											   initWithPath:path
											   ioQueue:self.photoIOQueue
											   locationManager:_locationManager
											   motionManager:_motionManager
											   completionHandler:^(NSString *_Nullable path,
																   NSDictionary *_Nullable metaData,
																   AVDepthData *_Nullable depthData,
																   NSError *_Nullable error) {

		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;
		dispatch_async(strongSelf.captureSessionQueue, ^{
			// cannot use the outter `strongSelf`
			typeof(self) strongSelf = weakSelf;
			if (!strongSelf) return;
			[strongSelf.inProgressSavePhotoDelegates removeObjectForKey:@(settings.uniqueID)];
		});

		if (error) {
			[result sendError:error];
		} else {
			NSAssert(path, @"Path must not be nil if no error.");

			// Save metadata to json file
			NSDictionary *sanitizedMetaData = [self sanitizeDictionary:metaData];
			NSError *error;
//			NSLog(@"Camera: Sanitized Metadata: %@",sanitizedMetaData);

			@try
			{
				NSData *jsonData = [NSJSONSerialization dataWithJSONObject:sanitizedMetaData options:NSJSONWritingPrettyPrinted error:&error];
				if (jsonData == nil )
				{
					[result sendError:error];
					return;
				}
//				NSLog(@"Camera: Metadata converted to JSON: %@",jsonData);
				[jsonData writeToFile:[path stringByAppendingString:@".json"] atomically:YES];
			}
			@catch( NSException *exception )
			{
				NSMutableDictionary * info = [NSMutableDictionary dictionary];
				[info setValue:exception.name forKey:@"ExceptionName"];
				[info setValue:exception.reason forKey:@"ExceptionReason"];
				[info setValue:exception.callStackReturnAddresses forKey:@"ExceptionCallStackReturnAddresses"];
				[info setValue:exception.callStackSymbols forKey:@"ExceptionCallStackSymbols"];
				[info setValue:exception.userInfo forKey:@"ExceptionUserInfo"];

				NSError *error = [[NSError alloc] initWithDomain:[[NSBundle mainBundle] bundleIdentifier] code:NSFileWriteUnknownError userInfo:info];
				NSLog(@"*** Unable to parse and save meta data: %@",exception);
				[result sendError:error];
				return;
			}

			// Save depth data to .depth file if it exists
			if (depthData != nil) {

				// get the raw pixel data from AVDepthData
				CVPixelBufferRef depthDataBuffer = [depthData depthDataMap];
//				NSLog(@"Camera: depthDataRaw = %@",depthDataRaw);
				NSData *depthDataRaw = [self convertCVPixelBufferToNSData:depthDataBuffer];

				// try to write the depth data to a file
				@try
				{
					[depthDataRaw writeToFile:[path stringByAppendingString:@".depth"] atomically:YES];
				}
				@catch( NSException *exception )
				{
					NSMutableDictionary * info = [NSMutableDictionary dictionary];
					[info setValue:exception.name forKey:@"ExceptionName"];
					[info setValue:exception.reason forKey:@"ExceptionReason"];
					[info setValue:exception.callStackReturnAddresses forKey:@"ExceptionCallStackReturnAddresses"];
					[info setValue:exception.callStackSymbols forKey:@"ExceptionCallStackSymbols"];
					[info setValue:exception.userInfo forKey:@"ExceptionUserInfo"];

					NSError *error = [[NSError alloc] initWithDomain:[[NSBundle mainBundle] bundleIdentifier] code:NSFileWriteUnknownError userInfo:info];
					NSLog(@"*** Unable to save depth data: %@",exception);
					[result sendError:error];
					return;	
				}
			}
			else
			{
				NSLog(@"Camera: No Depth Data");
			}

			[result sendSuccessWithData:path];
		}
	}];

	CLLocation *location = [_locationManager location];
	// NSLog(@"Init Location => %@ -> %@",_locationManager, location);

	NSAssert(dispatch_get_specific(FLTCaptureSessionQueueSpecific),
			 @"Save photo delegate references must be updated on the capture session queue.");
	self.inProgressSavePhotoDelegates[@(settings.uniqueID)] = savePhotoDelegate;
	NSLog(@"Camera: Capture Settings => %@", settings);
	NSLog(@"Camera: Capture Photo Output => %@",self.capturePhotoOutput);
	NSLog(@"Camera: Capture Photo Output (Depth Data Delivery Enabled) => %@", [self.capturePhotoOutput isDepthDataDeliveryEnabled] ? @"YES" : @"NO");
	NSLog(@"Camera: Capture Photo Output (Depth Data Delivery Supported) => %@", [self.capturePhotoOutput isDepthDataDeliverySupported] ? @"YES" : @"NO");
	[self.capturePhotoOutput setDepthDataDeliveryEnabled:[self.capturePhotoOutput isDepthDataDeliverySupported]];
	NSLog(@"Camera: Capture Photo Output [After Setting] (Depth Data Delivery Enabled) => %@", [self.capturePhotoOutput isDepthDataDeliveryEnabled] ? @"YES" : @"NO");

	[self.capturePhotoOutput capturePhotoWithSettings:settings delegate:savePhotoDelegate];
}

- (AVCaptureVideoOrientation)getVideoOrientationForDeviceOrientation:
(UIDeviceOrientation)deviceOrientation {
	if (deviceOrientation == UIDeviceOrientationPortrait) {
		return AVCaptureVideoOrientationPortrait;
	} else if (deviceOrientation == UIDeviceOrientationLandscapeLeft) {
		// Note: device orientation is flipped compared to video orientation. When UIDeviceOrientation
		// is landscape left the video orientation should be landscape right.
		return AVCaptureVideoOrientationLandscapeRight;
	} else if (deviceOrientation == UIDeviceOrientationLandscapeRight) {
		// Note: device orientation is flipped compared to video orientation. When UIDeviceOrientation
		// is landscape right the video orientation should be landscape left.
		return AVCaptureVideoOrientationLandscapeLeft;
	} else if (deviceOrientation == UIDeviceOrientationPortraitUpsideDown) {
		return AVCaptureVideoOrientationPortraitUpsideDown;
	} else {
		return AVCaptureVideoOrientationPortrait;
	}
}


- (NSString *)getTemporaryFilePathWithExtension:(NSString *)extension
									  subfolder:(NSString *)subfolder
										 prefix:(NSString *)prefix
										  error:(NSError *)error {
	NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
	// NSString *tmpDir = NSTemporaryDirectory();
	// NSString *picDir = NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSUserDomainMask, YES)[0];
	NSString *fileDir =
	[docDir stringByAppendingPathComponent:subfolder];
	NSString *fileName = [prefix stringByAppendingString:[[NSUUID UUID] UUIDString]];
	NSString *file =
	[[fileDir stringByAppendingPathComponent:fileName] stringByAppendingPathExtension:extension];

	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:fileDir]) {
		[[NSFileManager defaultManager] createDirectoryAtPath:fileDir
								  withIntermediateDirectories:true
												   attributes:nil
														error:&error];
		if (error) {
			return nil;
		}
	}

	return file;
}

- (void)setCaptureSessionPreset:(FLTResolutionPreset)resolutionPreset {
	switch (resolutionPreset) {
		case FLTResolutionPresetMax:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPresetPhoto;
				_previewSize = CGSizeMake(_captureDevice.activeFormat.highResolutionStillImageDimensions.width,
						   _captureDevice.activeFormat.highResolutionStillImageDimensions.height);
				break;
			}
		case FLTResolutionPresetUltraHigh:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset3840x2160]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPreset3840x2160;
				_previewSize = CGSizeMake(3840, 2160);
				break;
			}
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPresetHigh;
				_previewSize = CGSizeMake(_captureDevice.activeFormat.highResolutionStillImageDimensions.width,
						   _captureDevice.activeFormat.highResolutionStillImageDimensions.height);
				break;
			}
		case FLTResolutionPresetVeryHigh:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
				_previewSize = CGSizeMake(1920, 1080);
				break;
			}
		case FLTResolutionPresetHigh:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPreset1280x720;
				_previewSize = CGSizeMake(1280, 720);
				break;
			}
		case FLTResolutionPresetMedium:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset640x480]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPreset640x480;
				_previewSize = CGSizeMake(640, 480);
				break;
			}
		case FLTResolutionPresetLow:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPreset352x288]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPreset352x288;
				_previewSize = CGSizeMake(352, 288);
				break;
			}
		default:
			if ([_videoCaptureSession canSetSessionPreset:AVCaptureSessionPresetLow]) {
				_videoCaptureSession.sessionPreset = AVCaptureSessionPresetLow;
				_previewSize = CGSizeMake(352, 288);
			} else {
				NSError *error =
				[NSError errorWithDomain:NSCocoaErrorDomain
									code:NSURLErrorUnknown
								userInfo:@{
					NSLocalizedDescriptionKey :
						@"No capture session available for current capture session."
				}];
				@throw error;
			}
	}
	_audioCaptureSession.sessionPreset = _videoCaptureSession.sessionPreset;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	   fromConnection:(AVCaptureConnection *)connection {
	if (output == _captureVideoOutput) {
		CVPixelBufferRef newBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
		CFRetain(newBuffer);

		__block CVPixelBufferRef previousPixelBuffer = nil;
		// Use `dispatch_sync` to avoid unnecessary context switch under common non-contest scenarios;
		// Under rare contest scenarios, it will not block for too long since the critical section is
		// quite lightweight.
		dispatch_sync(self.pixelBufferSynchronizationQueue, ^{
			// No need weak self because it's dispatch_sync.
			previousPixelBuffer = self.latestPixelBuffer;
			self.latestPixelBuffer = newBuffer;
		});
		if (previousPixelBuffer) {
			CFRelease(previousPixelBuffer);
		}
		if (_onFrameAvailable) {
			_onFrameAvailable();
		}
	}
	if (!CMSampleBufferDataIsReady(sampleBuffer)) {
		[_methodChannel invokeMethod:errorMethod
						   arguments:@"sample buffer is not ready. Skipping sample"];
		return;
	}
	if (_isStreamingImages) {
		FlutterEventSink eventSink = _imageStreamHandler.eventSink;
		if (eventSink && (self.streamingPendingFramesCount < self.maxStreamingPendingFramesCount)) {
			self.streamingPendingFramesCount++;
			CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
			// Must lock base address before accessing the pixel data
			CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

			size_t imageWidth = CVPixelBufferGetWidth(pixelBuffer);
			size_t imageHeight = CVPixelBufferGetHeight(pixelBuffer);

			NSMutableArray *planes = [NSMutableArray array];

			const Boolean isPlanar = CVPixelBufferIsPlanar(pixelBuffer);
			size_t planeCount;
			if (isPlanar) {
				planeCount = CVPixelBufferGetPlaneCount(pixelBuffer);
			} else {
				planeCount = 1;
			}

			for (int i = 0; i < planeCount; i++) {
				void *planeAddress;
				size_t bytesPerRow;
				size_t height;
				size_t width;

				if (isPlanar) {
					planeAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, i);
					bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, i);
					height = CVPixelBufferGetHeightOfPlane(pixelBuffer, i);
					width = CVPixelBufferGetWidthOfPlane(pixelBuffer, i);
				} else {
					planeAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
					bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
					height = CVPixelBufferGetHeight(pixelBuffer);
					width = CVPixelBufferGetWidth(pixelBuffer);
				}

				NSNumber *length = @(bytesPerRow * height);
				NSData *bytes = [NSData dataWithBytes:planeAddress length:length.unsignedIntegerValue];

				NSMutableDictionary *planeBuffer = [NSMutableDictionary dictionary];
				planeBuffer[@"bytesPerRow"] = @(bytesPerRow);
				planeBuffer[@"width"] = @(width);
				planeBuffer[@"height"] = @(height);
				planeBuffer[@"bytes"] = [FlutterStandardTypedData typedDataWithBytes:bytes];

				[planes addObject:planeBuffer];
			}
			// Lock the base address before accessing pixel data, and unlock it afterwards.
			// Done accessing the `pixelBuffer` at this point.
			CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

			NSMutableDictionary *imageBuffer = [NSMutableDictionary dictionary];
			imageBuffer[@"width"] = [NSNumber numberWithUnsignedLong:imageWidth];
			imageBuffer[@"height"] = [NSNumber numberWithUnsignedLong:imageHeight];
			imageBuffer[@"format"] = @(_videoFormat);
			imageBuffer[@"planes"] = planes;
			imageBuffer[@"lensAperture"] = [NSNumber numberWithFloat:[_captureDevice lensAperture]];
			Float64 exposureDuration = CMTimeGetSeconds([_captureDevice exposureDuration]);
			Float64 nsExposureDuration = 1000000000 * exposureDuration;
			imageBuffer[@"sensorExposureTime"] = [NSNumber numberWithInt:nsExposureDuration];
			imageBuffer[@"sensorSensitivity"] = [NSNumber numberWithFloat:[_captureDevice ISO]];

			dispatch_async(dispatch_get_main_queue(), ^{
				eventSink(imageBuffer);
			});
		}
	}
	if (_isRecording && !_isRecordingPaused) {
		if (_videoWriter.status == AVAssetWriterStatusFailed) {
			[_methodChannel invokeMethod:errorMethod
							   arguments:[NSString stringWithFormat:@"%@", _videoWriter.error]];
			return;
		}

		CFRetain(sampleBuffer);
		CMTime currentSampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

		if (_videoWriter.status != AVAssetWriterStatusWriting) {
			[_videoWriter startWriting];
			[_videoWriter startSessionAtSourceTime:currentSampleTime];
		}

		if (output == _captureVideoOutput) {
			if (_videoIsDisconnected) {
				_videoIsDisconnected = NO;

				if (_videoTimeOffset.value == 0) {
					_videoTimeOffset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
				} else {
					CMTime offset = CMTimeSubtract(currentSampleTime, _lastVideoSampleTime);
					_videoTimeOffset = CMTimeAdd(_videoTimeOffset, offset);
				}

				return;
			}

			_lastVideoSampleTime = currentSampleTime;

			CVPixelBufferRef nextBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
			CMTime nextSampleTime = CMTimeSubtract(_lastVideoSampleTime, _videoTimeOffset);
			[_videoAdaptor appendPixelBuffer:nextBuffer withPresentationTime:nextSampleTime];
		} else {
			CMTime dur = CMSampleBufferGetDuration(sampleBuffer);

			if (dur.value > 0) {
				currentSampleTime = CMTimeAdd(currentSampleTime, dur);
			}

			if (_audioIsDisconnected) {
				_audioIsDisconnected = NO;

				if (_audioTimeOffset.value == 0) {
					_audioTimeOffset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
				} else {
					CMTime offset = CMTimeSubtract(currentSampleTime, _lastAudioSampleTime);
					_audioTimeOffset = CMTimeAdd(_audioTimeOffset, offset);
				}

				return;
			}

			_lastAudioSampleTime = currentSampleTime;

			if (_audioTimeOffset.value != 0) {
				CFRelease(sampleBuffer);
				sampleBuffer = [self adjustTime:sampleBuffer by:_audioTimeOffset];
			}

			[self newAudioSample:sampleBuffer];
		}

		CFRelease(sampleBuffer);
	}
}

- (CMSampleBufferRef)adjustTime:(CMSampleBufferRef)sample by:(CMTime)offset CF_RETURNS_RETAINED {
	CMItemCount count;
	CMSampleBufferGetSampleTimingInfoArray(sample, 0, nil, &count);
	CMSampleTimingInfo *pInfo = malloc(sizeof(CMSampleTimingInfo) * count);
	CMSampleBufferGetSampleTimingInfoArray(sample, count, pInfo, &count);
	for (CMItemCount i = 0; i < count; i++) {
		pInfo[i].decodeTimeStamp = CMTimeSubtract(pInfo[i].decodeTimeStamp, offset);
		pInfo[i].presentationTimeStamp = CMTimeSubtract(pInfo[i].presentationTimeStamp, offset);
	}
	CMSampleBufferRef sout;
	CMSampleBufferCreateCopyWithNewTiming(nil, sample, count, pInfo, &sout);
	free(pInfo);
	return sout;
}

- (void)newVideoSample:(CMSampleBufferRef)sampleBuffer {
	if (_videoWriter.status != AVAssetWriterStatusWriting) {
		if (_videoWriter.status == AVAssetWriterStatusFailed) {
			[_methodChannel invokeMethod:errorMethod
							   arguments:[NSString stringWithFormat:@"%@", _videoWriter.error]];
		}
		return;
	}
	if (_videoWriterInput.readyForMoreMediaData) {
		if (![_videoWriterInput appendSampleBuffer:sampleBuffer]) {
			[_methodChannel
			 invokeMethod:errorMethod
			 arguments:[NSString stringWithFormat:@"%@", @"Unable to write to video input"]];
		}
	}
}

- (void)newAudioSample:(CMSampleBufferRef)sampleBuffer {
	if (_videoWriter.status != AVAssetWriterStatusWriting) {
		if (_videoWriter.status == AVAssetWriterStatusFailed) {
			[_methodChannel invokeMethod:errorMethod
							   arguments:[NSString stringWithFormat:@"%@", _videoWriter.error]];
		}
		return;
	}
	if (_audioWriterInput.readyForMoreMediaData) {
		if (![_audioWriterInput appendSampleBuffer:sampleBuffer]) {
			[_methodChannel
			 invokeMethod:errorMethod
			 arguments:[NSString stringWithFormat:@"%@", @"Unable to write to audio input"]];
		}
	}
}

- (void)close {
	[self stop];
	for (AVCaptureInput *input in [_videoCaptureSession inputs]) {
		[_videoCaptureSession removeInput:input];
	}
	for (AVCaptureOutput *output in [_videoCaptureSession outputs]) {
		[_videoCaptureSession removeOutput:output];
	}
	for (AVCaptureInput *input in [_audioCaptureSession inputs]) {
		[_audioCaptureSession removeInput:input];
	}
	for (AVCaptureOutput *output in [_audioCaptureSession outputs]) {
		[_audioCaptureSession removeOutput:output];
	}
}

- (void)dealloc {
	if (_latestPixelBuffer) {
		CFRelease(_latestPixelBuffer);
	}
	[_motionManager stopDeviceMotionUpdates];
	[_motionManager stopAccelerometerUpdates];
	[_motionManager stopGyroUpdates];
	[_motionManager stopMagnetometerUpdates];
}

- (CVPixelBufferRef)copyPixelBuffer {
	__block CVPixelBufferRef pixelBuffer = nil;
	// Use `dispatch_sync` because `copyPixelBuffer` API requires synchronous return.
	dispatch_sync(self.pixelBufferSynchronizationQueue, ^{
		// No need weak self because it's dispatch_sync.
		pixelBuffer = self.latestPixelBuffer;
		self.latestPixelBuffer = nil;
	});
	return pixelBuffer;
}

- (void)startVideoRecordingWithResult:(FLTThreadSafeFlutterResult *)result {
	[self startVideoRecordingWithResult:result messengerForStreaming:nil];
}

- (void)startVideoRecordingWithResult:(FLTThreadSafeFlutterResult *)result
				messengerForStreaming:(nullable NSObject<FlutterBinaryMessenger> *)messenger {
	if (!_isRecording) {
		if (messenger != nil) {
			[self startImageStreamWithMessenger:messenger];
		}

		NSError *error;
		_videoRecordingPath = [self getTemporaryFilePathWithExtension:@"mp4"
															subfolder:@"videos"
															   prefix:@"REC_"
																error:error];
		if (error) {
			[result sendError:error];
			return;
		}
		if (![self setupWriterForPath:_videoRecordingPath]) {
			[result sendErrorWithCode:@"IOError" message:@"Setup Writer Failed" details:nil];
			return;
		}
		_isRecording = YES;
		_isRecordingPaused = NO;
		_videoTimeOffset = CMTimeMake(0, 1);
		_audioTimeOffset = CMTimeMake(0, 1);
		_videoIsDisconnected = NO;
		_audioIsDisconnected = NO;
		[result sendSuccess];
	} else {
		[result sendErrorWithCode:@"Error" message:@"Video is already recording" details:nil];
	}
}

- (void)stopVideoRecordingWithResult:(FLTThreadSafeFlutterResult *)result {
	if (_isRecording) {
		_isRecording = NO;

		if (_videoWriter.status != AVAssetWriterStatusUnknown) {
			[_videoWriter finishWritingWithCompletionHandler:^{
				if (self->_videoWriter.status == AVAssetWriterStatusCompleted) {
					[self updateOrientation];
					[result sendSuccessWithData:self->_videoRecordingPath];
					self->_videoRecordingPath = nil;
				} else {
					[result sendErrorWithCode:@"IOError"
									  message:@"AVAssetWriter could not finish writing!"
									  details:nil];
				}
			}];
		}
	} else {
		NSError *error =
		[NSError errorWithDomain:NSCocoaErrorDomain
							code:NSURLErrorResourceUnavailable
						userInfo:@{NSLocalizedDescriptionKey : @"Video is not recording!"}];
		[result sendError:error];
	}
}

- (void)pauseVideoRecordingWithResult:(FLTThreadSafeFlutterResult *)result {
	_isRecordingPaused = YES;
	_videoIsDisconnected = YES;
	_audioIsDisconnected = YES;
	[result sendSuccess];
}

- (void)resumeVideoRecordingWithResult:(FLTThreadSafeFlutterResult *)result {
	_isRecordingPaused = NO;
	[result sendSuccess];
}

- (void)lockCaptureOrientationWithResult:(FLTThreadSafeFlutterResult *)result
							 orientation:(NSString *)orientationStr {
	UIDeviceOrientation orientation;
	@try {
		orientation = FLTGetUIDeviceOrientationForString(orientationStr);
	} @catch (NSError *e) {
		[result sendError:e];
		return;
	}

	if (_lockedCaptureOrientation != orientation) {
		_lockedCaptureOrientation = orientation;
		[self updateOrientation];
	}

	[result sendSuccess];
}

- (void)unlockCaptureOrientationWithResult:(FLTThreadSafeFlutterResult *)result {
	_lockedCaptureOrientation = UIDeviceOrientationUnknown;
	[self updateOrientation];
	[result sendSuccess];
}

- (void)setFlashModeWithResult:(FLTThreadSafeFlutterResult *)result mode:(NSString *)modeStr {
	FLTFlashMode mode;
	@try {
		mode = FLTGetFLTFlashModeForString(modeStr);
	} @catch (NSError *e) {
		[result sendError:e];
		return;
	}
	if (mode == FLTFlashModeTorch) {
		if (!_captureDevice.hasTorch) {
			[result sendErrorWithCode:@"setFlashModeFailed"
							  message:@"Device does not support torch mode"
							  details:nil];
			return;
		}
		if (!_captureDevice.isTorchAvailable) {
			[result sendErrorWithCode:@"setFlashModeFailed"
							  message:@"Torch mode is currently not available"
							  details:nil];
			return;
		}
		if (_captureDevice.torchMode != AVCaptureTorchModeOn) {
			[_captureDevice lockForConfiguration:nil];
			[_captureDevice setTorchMode:AVCaptureTorchModeOn];
			[_captureDevice unlockForConfiguration];
		}
	} else {
		if (!_captureDevice.hasFlash) {
			[result sendErrorWithCode:@"setFlashModeFailed"
							  message:@"Device does not have flash capabilities"
							  details:nil];
			return;
		}
		AVCaptureFlashMode avFlashMode = FLTGetAVCaptureFlashModeForFLTFlashMode(mode);
		if (![_capturePhotoOutput.supportedFlashModes
			  containsObject:[NSNumber numberWithInt:((int)avFlashMode)]]) {
			[result sendErrorWithCode:@"setFlashModeFailed"
							  message:@"Device does not support this specific flash mode"
							  details:nil];
			return;
		}
		if (_captureDevice.torchMode != AVCaptureTorchModeOff) {
			[_captureDevice lockForConfiguration:nil];
			[_captureDevice setTorchMode:AVCaptureTorchModeOff];
			[_captureDevice unlockForConfiguration];
		}
	}
	_flashMode = mode;
	[result sendSuccess];
}

- (void)setExposureModeWithResult:(FLTThreadSafeFlutterResult *)result mode:(NSString *)modeStr {
	FLTExposureMode mode;
	@try {
		mode = FLTGetFLTExposureModeForString(modeStr);
	} @catch (NSError *e) {
		[result sendError:e];
		return;
	}
	_exposureMode = mode;
	[self applyExposureMode];
	[result sendSuccess];
}

- (void)applyExposureMode {
	[_captureDevice lockForConfiguration:nil];
	switch (_exposureMode) {
		case FLTExposureModeLocked:
			[_captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
			break;
		case FLTExposureModeAuto:
			if ([_captureDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
				[_captureDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
			} else {
				[_captureDevice setExposureMode:AVCaptureExposureModeAutoExpose];
			}
			break;
	}
	[_captureDevice unlockForConfiguration];
}

- (void)setFocusModeWithResult:(FLTThreadSafeFlutterResult *)result mode:(NSString *)modeStr {
	FLTFocusMode mode;
	@try {
		mode = FLTGetFLTFocusModeForString(modeStr);
	} @catch (NSError *e) {
		[result sendError:e];
		return;
	}
	_focusMode = mode;
	[self applyFocusMode];
	[result sendSuccess];
}

- (void)applyFocusMode {
	[self applyFocusMode:_focusMode onDevice:_captureDevice];
}

- (void)applyFocusMode:(FLTFocusMode)focusMode onDevice:(AVCaptureDevice *)captureDevice {
	[captureDevice lockForConfiguration:nil];
	switch (focusMode) {
		case FLTFocusModeLocked:
			if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
				[captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
			}
			break;
		case FLTFocusModeAuto:
			if ([captureDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
				[captureDevice setFocusMode:AVCaptureFocusModeContinuousAutoFocus];
			} else if ([captureDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
				[captureDevice setFocusMode:AVCaptureFocusModeAutoFocus];
			}
			break;
	}
	[captureDevice unlockForConfiguration];
}

- (void)pausePreviewWithResult:(FLTThreadSafeFlutterResult *)result {
	_isPreviewPaused = true;
	[result sendSuccess];
}

- (void)resumePreviewWithResult:(FLTThreadSafeFlutterResult *)result {
	_isPreviewPaused = false;
	[result sendSuccess];
}

- (void)setDescriptionWhileRecording:(NSString *)cameraName
							  result:(FLTThreadSafeFlutterResult *)result {
	if (!_isRecording) {
		[result sendErrorWithCode:@"setDescriptionWhileRecordingFailed"
						  message:@"Device was not recording"
						  details:nil];
		return;
	}

	_captureDevice = [AVCaptureDevice deviceWithUniqueID:cameraName];

	AVCaptureConnection *oldConnection =
	[_captureVideoOutput connectionWithMediaType:AVMediaTypeVideo];

	// Stop video capture from the old output.
	[_captureVideoOutput setSampleBufferDelegate:nil queue:nil];

	// Remove the old video capture connections.
	[_videoCaptureSession beginConfiguration];
	[_videoCaptureSession removeInput:_captureVideoInput];
	[_videoCaptureSession removeOutput:_captureVideoOutput];

	NSError *error = nil;
	AVCaptureConnection *newConnection = [self createConnection:&error];
	if (error) {
		[result sendError:error];
		return;
	}

	// Keep the same orientation the old connections had.
	if (oldConnection && newConnection.isVideoOrientationSupported) {
		newConnection.videoOrientation = oldConnection.videoOrientation;
	}

	// Add the new connections to the session.
	if (![_videoCaptureSession canAddInput:_captureVideoInput])
		[result sendErrorWithCode:@"VideoError" message:@"Unable switch video input" details:nil];
	[_videoCaptureSession addInputWithNoConnections:_captureVideoInput];
	if (![_videoCaptureSession canAddOutput:_captureVideoOutput])
		[result sendErrorWithCode:@"VideoError" message:@"Unable switch video output" details:nil];
	[_videoCaptureSession addOutputWithNoConnections:_captureVideoOutput];
	if (![_videoCaptureSession canAddConnection:newConnection])
		[result sendErrorWithCode:@"VideoError" message:@"Unable switch video connection" details:nil];
	[_videoCaptureSession addConnection:newConnection];
	
	[_videoCaptureSession commitConfiguration];

	[result sendSuccess];
}

- (CGPoint)getCGPointForCoordsWithOrientation:(UIDeviceOrientation)orientation
											x:(double)x
											y:(double)y {
	double oldX = x, oldY = y;
	switch (orientation) {
		case UIDeviceOrientationPortrait:  // 90 ccw
			y = 1 - oldX;
			x = oldY;
			break;
		case UIDeviceOrientationPortraitUpsideDown:  // 90 cw
			x = 1 - oldY;
			y = oldX;
			break;
		case UIDeviceOrientationLandscapeRight:  // 180
			x = 1 - x;
			y = 1 - y;
			break;
		case UIDeviceOrientationLandscapeLeft:
		default:
			// No rotation required
			break;
	}
	// NSLog(@"CGPointForCoords:  %f, %f => %f, %f (%ld==%ld)", oldX, oldY, x, y, (long)orientation, (long)UIDeviceOrientationPortrait );
	return CGPointMake(x, y);
}

- (void)setExposurePointWithResult:(FLTThreadSafeFlutterResult *)result x:(double)x y:(double)y {
	if (!_captureDevice.isExposurePointOfInterestSupported) {
		[result sendErrorWithCode:@"setExposurePointFailed"
						  message:@"Device does not have exposure point capabilities"
						  details:nil];
		return;
	}
	// UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
	UIDeviceOrientation orientation = (_lockedCaptureOrientation != UIDeviceOrientationUnknown)
									? _lockedCaptureOrientation
									: _deviceOrientation;
	[_captureDevice lockForConfiguration:nil];
	[_captureDevice setExposurePointOfInterest:[self getCGPointForCoordsWithOrientation:orientation
																					  x:x
																					  y:y]];
	[_captureDevice unlockForConfiguration];
	// Retrigger auto exposure
	[self applyExposureMode];
	[result sendSuccess];
}

- (void)setFocusPointWithResult:(FLTThreadSafeFlutterResult *)result x:(double)x y:(double)y {
	if (!_captureDevice.isFocusPointOfInterestSupported) {
		[result sendErrorWithCode:@"setFocusPointFailed"
						  message:@"Device does not have focus point capabilities"
						  details:nil];
		return;
	}
	// UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
	UIDeviceOrientation orientation = (_lockedCaptureOrientation != UIDeviceOrientationUnknown)
									? _lockedCaptureOrientation
									: _deviceOrientation;
	[_captureDevice lockForConfiguration:nil];

	[_captureDevice setFocusPointOfInterest:[self getCGPointForCoordsWithOrientation:orientation
																				   x:x
																				   y:y]];
	[_captureDevice unlockForConfiguration];
	// Retrigger auto focus
	[self applyFocusMode];
	[result sendSuccess];
}

- (void)setExposureOffsetWithResult:(FLTThreadSafeFlutterResult *)result offset:(double)offset {
	[_captureDevice lockForConfiguration:nil];
	[_captureDevice setExposureTargetBias:offset completionHandler:nil];
	[_captureDevice unlockForConfiguration];
	[result sendSuccessWithData:@(offset)];
}

- (void)startImageStreamWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
	[self startImageStreamWithMessenger:messenger
					 imageStreamHandler:[[FLTImageStreamHandler alloc]
										 initWithCaptureSessionQueue:_captureSessionQueue]];
}

- (void)startImageStreamWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger
				   imageStreamHandler:(FLTImageStreamHandler *)imageStreamHandler {
	if (!_isStreamingImages) {
		FlutterEventChannel *eventChannel = [FlutterEventChannel
											 eventChannelWithName:@"plugins.flutter.io/camera_avfoundation/imageStream"
											 binaryMessenger:messenger];
		FLTThreadSafeEventChannel *threadSafeEventChannel =
		[[FLTThreadSafeEventChannel alloc] initWithEventChannel:eventChannel];

		_imageStreamHandler = imageStreamHandler;
		__weak typeof(self) weakSelf = self;
		[threadSafeEventChannel setStreamHandler:_imageStreamHandler
									  completion:^{
			typeof(self) strongSelf = weakSelf;
			if (!strongSelf) return;

			dispatch_async(strongSelf.captureSessionQueue, ^{
				// cannot use the outter strongSelf
				typeof(self) strongSelf = weakSelf;
				if (!strongSelf) return;

				strongSelf.isStreamingImages = YES;
				strongSelf.streamingPendingFramesCount = 0;
			});
		}];
	} else {
		[_methodChannel invokeMethod:errorMethod
						   arguments:@"Images from camera are already streaming!"];
	}
}

- (void)stopImageStream {
	if (_isStreamingImages) {
		_isStreamingImages = NO;
		_imageStreamHandler = nil;
	} else {
		[_methodChannel invokeMethod:errorMethod arguments:@"Images from camera are not streaming!"];
	}
}

- (void)receivedImageStreamData {
	self.streamingPendingFramesCount--;
}

- (void)getMaxZoomLevelWithResult:(FLTThreadSafeFlutterResult *)result {
	CGFloat maxZoomFactor = [self getMaxAvailableZoomFactor];

	[result sendSuccessWithData:[NSNumber numberWithFloat:maxZoomFactor]];
}

- (void)getMinZoomLevelWithResult:(FLTThreadSafeFlutterResult *)result {
	CGFloat minZoomFactor = [self getMinAvailableZoomFactor];
	[result sendSuccessWithData:[NSNumber numberWithFloat:minZoomFactor]];
}

- (void)setZoomLevel:(CGFloat)zoom Result:(FLTThreadSafeFlutterResult *)result {
	CGFloat maxAvailableZoomFactor = [self getMaxAvailableZoomFactor];
	CGFloat minAvailableZoomFactor = [self getMinAvailableZoomFactor];

	if (maxAvailableZoomFactor < zoom || minAvailableZoomFactor > zoom) {
		NSString *errorMessage = [NSString
								  stringWithFormat:@"Zoom level out of bounds (zoom level should be between %f and %f).",
								  minAvailableZoomFactor, maxAvailableZoomFactor];

		[result sendErrorWithCode:@"ZOOM_ERROR" message:errorMessage details:nil];
		return;
	}

	NSError *error = nil;
	if (![_captureDevice lockForConfiguration:&error]) {
		[result sendError:error];
		return;
	}
	_captureDevice.videoZoomFactor = zoom;
	[_captureDevice unlockForConfiguration];

	[result sendSuccess];
}

- (void)setZoomLevel:(CGFloat)zoom {

	CGFloat maxAvailableZoomFactor = [self getMaxAvailableZoomFactor];
	CGFloat minAvailableZoomFactor = [self getMinAvailableZoomFactor];

	if( zoom < minAvailableZoomFactor ) zoom = minAvailableZoomFactor;
	if( zoom > maxAvailableZoomFactor ) zoom = maxAvailableZoomFactor;

	NSError *error = nil;
	if (![_captureDevice lockForConfiguration:&error]) {
		NSLog(@"Camera: Error setting zoom level to %0.2f: %@",zoom,error);
		return;
	}
	NSLog(@"Camera:  Set Zoom factor to %0.2f",zoom);
	_captureDevice.videoZoomFactor = zoom;
	[_captureDevice unlockForConfiguration];
}

- (CGFloat)getMinAvailableZoomFactor {
	if (@available(iOS 16.0, *)) {
		if( _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.count > 0 ) {
//			NSLog(@"%@ %@", @"supportedVideoZoomFactorsForDepthDataDelivery", _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery);
			return _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.firstObject.floatValue;
		}
	}
	return _captureDevice.minAvailableVideoZoomFactor;
}

- (CGFloat)getMaxAvailableZoomFactor {
	if (@available(iOS 16.0, *)) {
		if( _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.count > 0 ) {
//			NSLog(@"%@ %@", @"supportedVideoZoomFactorsForDepthDataDelivery", _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery);
			return _captureDevice.activeFormat.supportedVideoZoomFactorsForDepthDataDelivery.lastObject.floatValue;
		}
	}
	return _captureDevice.maxAvailableVideoZoomFactor;
}

- (BOOL)setupWriterForPath:(NSString *)path {
	NSError *error = nil;
	NSURL *outputURL;
	if (path != nil) {
		outputURL = [NSURL fileURLWithPath:path];
	} else {
		return NO;
	}
	if (_enableAudio && !_isAudioSetup) {
		[self setUpCaptureSessionForAudio];
	}

	_videoWriter = [[AVAssetWriter alloc] initWithURL:outputURL
											 fileType:AVFileTypeMPEG4
												error:&error];
	NSParameterAssert(_videoWriter);
	if (error) {
		[_methodChannel invokeMethod:errorMethod arguments:error.description];
		return NO;
	}

	NSDictionary *videoSettings = [_captureVideoOutput
								   recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeMPEG4];
	_videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
														   outputSettings:videoSettings];

	_videoAdaptor = [AVAssetWriterInputPixelBufferAdaptor
					 assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_videoWriterInput
					 sourcePixelBufferAttributes:@{
		(NSString *)kCVPixelBufferPixelFormatTypeKey : @(_videoFormat)
	}];

	NSParameterAssert(_videoWriterInput);

	_videoWriterInput.expectsMediaDataInRealTime = YES;

	// Add the audio input
	if (_enableAudio) {
		AudioChannelLayout acl;
		bzero(&acl, sizeof(acl));
		acl.mChannelLayoutTag = kAudioChannelLayoutTag_Mono;
		NSDictionary *audioOutputSettings = nil;
		// Both type of audio inputs causes output video file to be corrupted.
		audioOutputSettings = @{
			AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatMPEG4AAC],
			AVSampleRateKey : [NSNumber numberWithFloat:44100.0],
			AVNumberOfChannelsKey : [NSNumber numberWithInt:1],
			AVChannelLayoutKey : [NSData dataWithBytes:&acl length:sizeof(acl)],
		};
		_audioWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
															   outputSettings:audioOutputSettings];
		_audioWriterInput.expectsMediaDataInRealTime = YES;

		[_videoWriter addInput:_audioWriterInput];
		[_audioOutput setSampleBufferDelegate:self queue:_captureSessionQueue];
	}

	if (_flashMode == FLTFlashModeTorch) {
		[self.captureDevice lockForConfiguration:nil];
		[self.captureDevice setTorchMode:AVCaptureTorchModeOn];
		[self.captureDevice unlockForConfiguration];
	}

	[_videoWriter addInput:_videoWriterInput];

	[_captureVideoOutput setSampleBufferDelegate:self queue:_captureSessionQueue];

	return YES;
}

- (void)setUpCaptureSessionForAudio {
	// Don't setup audio twice or we will lose the audio.
	if (_isAudioSetup) {
		return;
	}

	NSError *error = nil;
	// Create a device input with the device and add it to the session.
	// Setup the audio input.
	AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
	AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice
																			 error:&error];
	if (error) {
		[_methodChannel invokeMethod:errorMethod arguments:error.description];
	}
	// Setup the audio output.
	_audioOutput = [[AVCaptureAudioDataOutput alloc] init];

	if ([_audioCaptureSession canAddInput:audioInput]) {
		[_audioCaptureSession addInput:audioInput];

		if ([_audioCaptureSession canAddOutput:_audioOutput]) {
			[_audioCaptureSession addOutput:_audioOutput];
			_isAudioSetup = YES;
		} else {
			[_methodChannel invokeMethod:errorMethod
							   arguments:@"Unable to add Audio input/output to session capture"];
			_isAudioSetup = NO;
		}
	}
}
@end
