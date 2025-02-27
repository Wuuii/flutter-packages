// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "CameraPlugin.h"
#import "CameraPlugin_Test.h"

@import AVFoundation;
@import CoreLocation;
@import CoreMotion;

#import "CameraPermissionUtils.h"
#import "CameraProperties.h"
#import "FLTCam.h"
#import "FLTThreadSafeEventChannel.h"
#import "FLTThreadSafeFlutterResult.h"
#import "FLTThreadSafeMethodChannel.h"
#import "FLTThreadSafeTextureRegistry.h"
#import "QueueUtils.h"

@interface CameraPlugin ()
@property(readonly, nonatomic) FLTThreadSafeTextureRegistry *registry;
@property(readonly, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(nonatomic) CLLocationManager *locationManager;
@property(nonatomic) CMMotionManager *motionManager;
@end

@implementation CameraPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/camera_avfoundation"
                                  binaryMessenger:[registrar messenger]];
  CameraPlugin *instance = [[CameraPlugin alloc] initWithRegistry:[registrar textures]
                                                        messenger:[registrar messenger]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry
                       messenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [[FLTThreadSafeTextureRegistry alloc] initWithTextureRegistry:registry];
  _messenger = messenger;
  _captureSessionQueue = dispatch_queue_create("io.flutter.camera.captureSessionQueue", NULL);
  dispatch_queue_set_specific(_captureSessionQueue, FLTCaptureSessionQueueSpecific,
                              (void *)FLTCaptureSessionQueueSpecific, NULL);

  [self initDeviceEventMethodChannel];
  [self startOrientationListener];
  [self initLocationManager];
  [self initMotionManager];
  return self;
}

- (void)initDeviceEventMethodChannel {
  FlutterMethodChannel *methodChannel = [FlutterMethodChannel
      methodChannelWithName:@"plugins.flutter.io/camera_avfoundation/fromPlatform"
            binaryMessenger:_messenger];
  _deviceEventMethodChannel =
      [[FLTThreadSafeMethodChannel alloc] initWithMethodChannel:methodChannel];
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [UIDevice.currentDevice endGeneratingDeviceOrientationNotifications];
}

- (void)startOrientationListener {
  [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(orientationChanged:)
                                               name:UIDeviceOrientationDidChangeNotification
                                             object:[UIDevice currentDevice]];
}

- (void)orientationChanged:(NSNotification *)note {
  UIDevice *device = note.object;
  UIDeviceOrientation orientation = device.orientation;

  if (orientation == UIDeviceOrientationFaceUp || orientation == UIDeviceOrientationFaceDown) {
    // Do not change when oriented flat.
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_async(self.captureSessionQueue, ^{
    // `FLTCam::setDeviceOrientation` must be called on capture session queue.
    [weakSelf.camera setDeviceOrientation:orientation];
    // `CameraPlugin::sendDeviceOrientation` can be called on any queue.
    [weakSelf sendDeviceOrientation:orientation];
  });
}

- (void)sendDeviceOrientation:(UIDeviceOrientation)orientation {
  [_deviceEventMethodChannel
      invokeMethod:@"orientation_changed"
         arguments:@{@"orientation" : FLTGetStringForUIDeviceOrientation(orientation)}];
}

- (void)initLocationManager {
  self.locationManager = [[CLLocationManager alloc] init];
}

- (void)initMotionManager {
  // TODO(kb): Should try using CMBatchedSensorManager when ios 17 is released.
  self.motionManager = [[CMMotionManager alloc] init];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  // Invoke the plugin on another dispatch queue to avoid blocking the UI.
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.captureSessionQueue, ^{
    FLTThreadSafeFlutterResult *threadSafeResult =
        [[FLTThreadSafeFlutterResult alloc] initWithResult:result];
    [weakSelf handleMethodCallAsync:call result:threadSafeResult];
  });
}

- (void)handleMethodCallAsync:(FlutterMethodCall *)call
                       result:(FLTThreadSafeFlutterResult *)result {
  if ([@"availableCameras" isEqualToString:call.method]) {
    NSMutableArray *discoveryDevices =
        [@[ AVCaptureDeviceTypeBuiltInWideAngleCamera, 
        AVCaptureDeviceTypeBuiltInTelephotoCamera, 
        AVCaptureDeviceTypeBuiltInDualCamera ]
            mutableCopy];
    if (@available(iOS 11.1, *)) {
      [discoveryDevices addObject:AVCaptureDeviceTypeBuiltInTrueDepthCamera];
    }
    if (@available(iOS 13.0, *)) {
      [discoveryDevices addObject:AVCaptureDeviceTypeBuiltInUltraWideCamera];
      [discoveryDevices addObject:AVCaptureDeviceTypeBuiltInDualWideCamera];
      [discoveryDevices addObject:AVCaptureDeviceTypeBuiltInTripleCamera];
    }
    if (@available(iOS 15.4, *)) {
      [discoveryDevices addObject:AVCaptureDeviceTypeBuiltInLiDARDepthCamera];
    }
    // NSLog(@"cameraDeviceTypes: %@", discoveryDevices);
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:discoveryDevices
                              mediaType:AVMediaTypeVideo
                               position:AVCaptureDevicePositionUnspecified];
    NSArray<AVCaptureDevice *> *devices = discoverySession.devices;
    // NSLog(@"cameraDevicesFound: %@", devices);
    NSMutableArray<NSDictionary<NSString *, NSObject *> *> *reply =
        [[NSMutableArray alloc] initWithCapacity:devices.count];
    for (AVCaptureDevice *device in devices) {
      NSString *lensFacing;
      switch ([device position]) {
        case AVCaptureDevicePositionBack:
          lensFacing = @"back";
          break;
        case AVCaptureDevicePositionFront:
          lensFacing = @"front";
          break;
        case AVCaptureDevicePositionUnspecified:
          lensFacing = @"external";
          break;
      }
      // NSLog(@"device: %@", device);
      // NSLog(@"device.activeFormat: %@", device.activeFormat);

      // NSLog(@"device.activeDepthFormat: %@", device.activeDepthDataFormat);
      // NSLog(@"device.activeFormat.maxZoomFactor: %f", device.activeFormat.videoMaxZoomFactor);
      // NSLog(@"device.activeDepthDataFormat.maxZoomFactor: %f", device.activeDepthDataFormat.videoMaxZoomFactor);

      // NSLog(@"device.videoZoomFactor: %f", device.videoZoomFactor);
      // NSLog(@"device.minAvailableVideoZoomFactor: %f", device.minAvailableVideoZoomFactor);
      // NSLog(@"device.maxAvailableVideoZoomFactor: %f", device.maxAvailableVideoZoomFactor);

      double fov = device.activeFormat.videoFieldOfView;
      double depthFov = device.activeFormat.videoFieldOfView;
      double maxZoomFactor = device.activeFormat.videoMaxZoomFactor;
      if( device.activeDepthDataFormat != nil ) {
        depthFov = device.activeDepthDataFormat.videoFieldOfView;
        maxZoomFactor = device.activeDepthDataFormat.videoMaxZoomFactor;
      }
      [reply addObject:@{
        @"name" : [device uniqueID],
        @"localizedName" : [device localizedName],
		    @"fov" : [NSNumber numberWithFloat:fov],
        @"fovDepth" : [NSNumber numberWithFloat:depthFov],
        @"maxZoomFactor" : [NSNumber numberWithFloat:maxZoomFactor],
        @"depthSupported" : [[[device activeFormat] supportedDepthDataFormats] count] > 0 ? @YES : @NO,
        @"lensFacing" : lensFacing,
        @"sensorOrientation" : @90,
      }];
    }
    NSLog(@"cameras => %@",reply);
    [result sendSuccessWithData:reply];
  } else if ([@"create" isEqualToString:call.method]) {
    [self handleCreateMethodCall:call result:result];
  } else if ([@"startImageStream" isEqualToString:call.method]) {
    [_camera startImageStreamWithMessenger:_messenger];
    [result sendSuccess];
  } else if ([@"stopImageStream" isEqualToString:call.method]) {
    [_camera stopImageStream];
    [result sendSuccess];
  } else if ([@"receivedImageStreamData" isEqualToString:call.method]) {
    [_camera receivedImageStreamData];
    [result sendSuccess];
  } else {
    NSDictionary *argsMap = call.arguments;
    NSUInteger cameraId = ((NSNumber *)argsMap[@"cameraId"]).unsignedIntegerValue;
    if ([@"initialize" isEqualToString:call.method]) {
      NSString *videoFormatValue = ((NSString *)argsMap[@"imageFormatGroup"]);
      [_camera setVideoFormat:FLTGetVideoFormatFromString(videoFormatValue)];

      __weak CameraPlugin *weakSelf = self;
      _camera.onFrameAvailable = ^{
        if (![weakSelf.camera isPreviewPaused]) {
          [weakSelf.registry textureFrameAvailable:cameraId];
        }
      };
      FlutterMethodChannel *methodChannel = [FlutterMethodChannel
          methodChannelWithName:
              [NSString stringWithFormat:@"plugins.flutter.io/camera_avfoundation/camera%lu",
                                         (unsigned long)cameraId]
                binaryMessenger:_messenger];
      FLTThreadSafeMethodChannel *threadSafeMethodChannel =
          [[FLTThreadSafeMethodChannel alloc] initWithMethodChannel:methodChannel];
      _camera.methodChannel = threadSafeMethodChannel;
      [threadSafeMethodChannel
          invokeMethod:@"initialized"
             arguments:@{
               @"previewWidth" : @(_camera.previewSize.width),
               @"previewHeight" : @(_camera.previewSize.height),
               @"exposureMode" : FLTGetStringForFLTExposureMode([_camera exposureMode]),
               @"focusMode" : FLTGetStringForFLTFocusMode([_camera focusMode]),
               @"exposurePointSupported" :
                   @([_camera.captureDevice isExposurePointOfInterestSupported]),
               @"focusPointSupported" : @([_camera.captureDevice isFocusPointOfInterestSupported]),
             }];
      [self sendDeviceOrientation:[UIDevice currentDevice].orientation];
      [_camera start];
      [result sendSuccess];
    } else if ([@"takePicture" isEqualToString:call.method]) {
      [_camera captureToFile:result];
    } else if ([@"dispose" isEqualToString:call.method]) {
      [_registry unregisterTexture:cameraId];
      [_camera close];
      [result sendSuccess];
    } else if ([@"prepareForVideoRecording" isEqualToString:call.method]) {
      [self.camera setUpCaptureSessionForAudio];
      [result sendSuccess];
    } else if ([@"startVideoRecording" isEqualToString:call.method]) {
      BOOL enableStream = [call.arguments[@"enableStream"] boolValue];
      if (enableStream) {
        [_camera startVideoRecordingWithResult:result messengerForStreaming:_messenger];
      } else {
        [_camera startVideoRecordingWithResult:result];
      }
    } else if ([@"stopVideoRecording" isEqualToString:call.method]) {
      [_camera stopVideoRecordingWithResult:result];
    } else if ([@"pauseVideoRecording" isEqualToString:call.method]) {
      [_camera pauseVideoRecordingWithResult:result];
    } else if ([@"resumeVideoRecording" isEqualToString:call.method]) {
      [_camera resumeVideoRecordingWithResult:result];
    } else if ([@"getMaxZoomLevel" isEqualToString:call.method]) {
      [_camera getMaxZoomLevelWithResult:result];
    } else if ([@"getMinZoomLevel" isEqualToString:call.method]) {
      [_camera getMinZoomLevelWithResult:result];
    } else if ([@"setZoomLevel" isEqualToString:call.method]) {
      CGFloat zoom = ((NSNumber *)argsMap[@"zoom"]).floatValue;
      [_camera setZoomLevel:zoom Result:result];
    } else if ([@"setFlashMode" isEqualToString:call.method]) {
      [_camera setFlashModeWithResult:result mode:call.arguments[@"mode"]];
    } else if ([@"setExposureMode" isEqualToString:call.method]) {
      [_camera setExposureModeWithResult:result mode:call.arguments[@"mode"]];
    } else if ([@"setExposurePoint" isEqualToString:call.method]) {
      BOOL reset = ((NSNumber *)call.arguments[@"reset"]).boolValue;
      double x = 0.5;
      double y = 0.5;
      if (!reset) {
        x = ((NSNumber *)call.arguments[@"x"]).doubleValue;
        y = ((NSNumber *)call.arguments[@"y"]).doubleValue;
      }
      [_camera setExposurePointWithResult:result x:x y:y];
    } else if ([@"getMinExposureOffset" isEqualToString:call.method]) {
      [result sendSuccessWithData:@(_camera.captureDevice.minExposureTargetBias)];
    } else if ([@"getMaxExposureOffset" isEqualToString:call.method]) {
      [result sendSuccessWithData:@(_camera.captureDevice.maxExposureTargetBias)];
    } else if ([@"getExposureOffsetStepSize" isEqualToString:call.method]) {
      [result sendSuccessWithData:@(0.0)];
    } else if ([@"setExposureOffset" isEqualToString:call.method]) {
      [_camera setExposureOffsetWithResult:result
                                    offset:((NSNumber *)call.arguments[@"offset"]).doubleValue];
    } else if ([@"lockCaptureOrientation" isEqualToString:call.method]) {
      [_camera lockCaptureOrientationWithResult:result orientation:call.arguments[@"orientation"]];
    } else if ([@"unlockCaptureOrientation" isEqualToString:call.method]) {
      [_camera unlockCaptureOrientationWithResult:result];
    } else if ([@"setFocusMode" isEqualToString:call.method]) {
      [_camera setFocusModeWithResult:result mode:call.arguments[@"mode"]];
    } else if ([@"setFocusPoint" isEqualToString:call.method]) {
      BOOL reset = ((NSNumber *)call.arguments[@"reset"]).boolValue;
      double x = 0.5;
      double y = 0.5;
      if (!reset) {
        x = ((NSNumber *)call.arguments[@"x"]).doubleValue;
        y = ((NSNumber *)call.arguments[@"y"]).doubleValue;
      }
      [_camera setFocusPointWithResult:result x:x y:y];
    } else if ([@"pausePreview" isEqualToString:call.method]) {
      [_camera pausePreviewWithResult:result];
    } else if ([@"resumePreview" isEqualToString:call.method]) {
      [_camera resumePreviewWithResult:result];
    } else if ([@"setDescriptionWhileRecording" isEqualToString:call.method]) {
      [_camera setDescriptionWhileRecording:(call.arguments[@"cameraName"]) result:result];
    } else {
      [result sendNotImplemented];
    }
  }
}

- (void)handleCreateMethodCall:(FlutterMethodCall *)call
                        result:(FLTThreadSafeFlutterResult *)result {
  // Create FLTCam only if granted camera access (and audio access if audio is enabled)
  __weak typeof(self) weakSelf = self;
  FLTRequestCameraPermissionWithCompletionHandler(^(FlutterError *error) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;

    if (error) {
      [result sendFlutterError:error];
    } else {
      // Create core location manager, and request permission if necessary.
      // strongSelf->_locationManager = [[CLLocationManager alloc] init];

      switch ([CLLocationManager authorizationStatus]) {
        case kCLAuthorizationStatusAuthorizedWhenInUse:
            NSLog(@"Camera: Location permission granted, will add GPS metadata to photos."); 
            break;

        case kCLAuthorizationStatusNotDetermined:
            [strongSelf->_locationManager requestWhenInUseAuthorization];
            // locationManagerStatus = CLLocationManager.authorizationStatus();

        default:
            // locationManagerStatus = .denied;
            NSLog(@"*** Camera: Location permission denied, unable to add GPS metadata to photos.");
      }

      // Request audio permission on `create` call with `enableAudio` argument instead of the
      // `prepareForVideoRecording` call. This is because `prepareForVideoRecording` call is
      // optional, and used as a workaround to fix a missing frame issue on iOS.
      BOOL audioEnabled = [call.arguments[@"enableAudio"] boolValue];
      if (audioEnabled) {
        // Setup audio capture session only if granted audio access.
        FLTRequestAudioPermissionWithCompletionHandler(^(FlutterError *error) {
          // cannot use the outter `strongSelf`
          typeof(self) strongSelf = weakSelf;
          if (!strongSelf) return;
          if (error) {
            [result sendFlutterError:error];
          } else {
            [strongSelf createCameraOnSessionQueueWithCreateMethodCall:call locationManager:strongSelf->_locationManager motionManager:strongSelf->_motionManager result:result];
          }
        });
      } else {
        [strongSelf createCameraOnSessionQueueWithCreateMethodCall:call locationManager:strongSelf->_locationManager motionManager:strongSelf->_motionManager result:result];
      }
    }
  });
}

- (void)createCameraOnSessionQueueWithCreateMethodCall:(FlutterMethodCall *)createMethodCall
                                      locationManager:(CLLocationManager *)locationManager
                                      motionManager:(CMMotionManager *)motionManager
                                                result:(FLTThreadSafeFlutterResult *)result {
  __weak typeof(self) weakSelf = self;
  dispatch_async(self.captureSessionQueue, ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;

    NSString *cameraName = createMethodCall.arguments[@"cameraName"];
    NSString *resolutionPreset = createMethodCall.arguments[@"resolutionPreset"];
    NSNumber *enableAudio = createMethodCall.arguments[@"enableAudio"];
    NSError *error;
    FLTCam *cam = [[FLTCam alloc] initWithCameraName:cameraName
                                    resolutionPreset:resolutionPreset
                                         enableAudio:[enableAudio boolValue]
                                         orientation:[[UIDevice currentDevice] orientation]
                                 captureSessionQueue:strongSelf.captureSessionQueue
                                     locationManager:locationManager
                                       motionManager:motionManager
                                               error:&error];

    if (error) {
      [result sendError:error];
    } else {
      if (strongSelf.camera) {
        [strongSelf.camera close];
      }
      strongSelf.camera = cam;
      [strongSelf.registry registerTexture:cam
                                completion:^(int64_t textureId) {
                                  [result sendSuccessWithData:@{
                                    @"cameraId" : @(textureId),
                                  }];
                                }];
    }
  });
}

@end
