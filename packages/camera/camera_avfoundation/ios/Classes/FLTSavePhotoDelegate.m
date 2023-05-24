// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FLTSavePhotoDelegate.h"
#import "FLTSavePhotoDelegate_Test.h"

@interface FLTSavePhotoDelegate ()
/// The file path for the captured photo.
@property(readonly, nonatomic) NSString *path;
/// The location manager used to get the current location.
@property(readonly, nonatomic) CLLocationManager *locationManager;
/// The location manager used to get the current location.
@property(readonly, nonatomic) CMMotionManager *motionManager;
/// The metadata for photo
@property(nonatomic) NSDictionary *metaData;
/// The queue on which captured photos are written to disk.
@property(readonly, nonatomic) dispatch_queue_t ioQueue;
@end

@implementation FLTSavePhotoDelegate

- (instancetype)initWithPath:(NSString *)path
					 ioQueue:(dispatch_queue_t)ioQueue
			 locationManager:(CLLocationManager *)locationManager
			   motionManager:(CMMotionManager *)motionManager
		   completionHandler:(FLTSavePhotoDelegateCompletionHandler)completionHandler {
	self = [super init];
	NSAssert(self, @"super init cannot be nil");
	_path = path;
	_ioQueue = ioQueue;
	_locationManager = locationManager;
	_motionManager = motionManager;
	_completionHandler = completionHandler;
	return self;
}

- (void)handlePhotoCaptureResultWithError:(NSError *)error
						photoDataProvider:(NSData * (^)(void))photoDataProvider {
	if (error) {
		self.completionHandler(nil, nil, error);
		return;
	}
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.ioQueue, ^{
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;

		NSData *data = photoDataProvider();
		NSError *ioError;
		if ([data writeToFile:strongSelf.path options:NSDataWritingAtomic error:&ioError]) {
			strongSelf.completionHandler(self.path, nil, nil);
		} else {
			strongSelf.completionHandler(nil, nil, ioError);
		}
	});
}

- (void)handlePhotoCaptureResultWithError:(NSError *)error
//						photoDataProvider:(NSData * (^)(void))photoDataProvider
									photo:(AVCapturePhoto *)photo
								 metaData:(NSDictionary *)metaData {
	if (error) {
		self.completionHandler(nil, nil, error);
		return;
	}
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.ioQueue, ^{
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;

		//NSLog(@"self.path: %@", self.path);

		NSData *data = [photo fileDataRepresentationWithCustomizer:self];
		NSMutableDictionary *mutableMetaData = [self->_metaData mutableCopy];
		[mutableMetaData addEntriesFromDictionary:[self extendedMetadataForPhoto:photo]];

		// NSLog(@"mutableMetaData: %@", mutableMetaData);

		NSError *ioError;
		if ([data writeToFile:strongSelf.path options:NSDataWritingAtomic error:&ioError]) {
			strongSelf.completionHandler(self.path, mutableMetaData, nil);
		} else {
			strongSelf.completionHandler(nil, nil, ioError);
		}
	});
}


// 	<CGImageMetadataTag 0x600000231f40> exif:GPSLatitude = 37,30.1893N
// 	<CGImageMetadataTag 0x600000231fa0> exif:GPSLongitude = 122,15.5873W
// 	<CGImageMetadataTag 0x600000232060> exif:GPSImgDirection = 340349/15847
// 	<CGImageMetadataTag 0x600000232080> exif:GPSDestBearingRef = M
// 	<CGImageMetadataTag 0x600000231ee0> exif:GPSAltitudeRef = 0
// 	<CGImageMetadataTag 0x600000232020> exif:GPSImgDirectionRef = M
// 	<CGImageMetadataTag 0x6000002320c0> exif:GPSDestBearing = 432773/2148
// 	<CGImageMetadataTag 0x600000232000> exif:GPSSpeed = 0/1
// 	<CGImageMetadataTag 0x600000231fc0> exif:GPSAltitude = 113480/9309
// 	<CGImageMetadataTag 0x600000232100> exif:GPSHPositioningError = 94244/20653
// 	<CGImageMetadataTag 0x600000231fe0> exif:GPSSpeedRef = K

// Copied from:  https://gist.github.com/Sumolari/4e0a5c6cdb4fa47b0cb2db8dafe5056a
- (NSDictionary *)GPSDictionaryForLocation:(CLLocation *)location heading:(CLHeading *)heading
{
	NSMutableDictionary *gps = [NSMutableDictionary dictionary];

	// Example:
	/*
	 "{GPS}" =     {
	 Altitude = "41.28771929824561";
	 AltitudeRef = 0;
	 DateStamp = "2014:07:21";
	 ImgDirection = "68.2140221402214";
	 ImgDirectionRef = T;
	 Latitude = "37.74252";
	 LatitudeRef = N;
	 Longitude = "122.42035";
	 LongitudeRef = W;
	 TimeStamp = "15:53:24";
	 };
	 */

	// GPS tag version
	// According to http://www.cipa.jp/std/documents/e/DC-008-2012_E.pdf,
	// this value is 2.3.0.0
	[gps setObject:@"2.3.0.0" forKey:(NSString *)kCGImagePropertyGPSVersion];

	// Time and date must be provided as strings, not as an NSDate object
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
	formatter.dateFormat = @"HH:mm:ss.SSSSSS";
	gps[(NSString *)kCGImagePropertyGPSTimeStamp] = [formatter stringFromDate:location.timestamp];
	formatter.dateFormat = @"yyyy:MM:dd";
	gps[(NSString *)kCGImagePropertyGPSDateStamp] = [formatter stringFromDate:location.timestamp];

	// Latitude
	CLLocationDegrees latitude = location.coordinate.latitude;
	gps[(NSString *)kCGImagePropertyGPSLatitudeRef] = (latitude < 0) ? @"S" : @"N";
	gps[(NSString *)kCGImagePropertyGPSLatitude] = @(fabs(latitude));

	// Longitude
	CLLocationDegrees longitude = location.coordinate.longitude;
	gps[(NSString *)kCGImagePropertyGPSLongitudeRef] = (longitude < 0) ? @"W" : @"E";
	gps[(NSString *)kCGImagePropertyGPSLongitude] = @(fabs(longitude));

	// Degree of Precision
	gps[(NSString *)kCGImagePropertyGPSDOP] = @(location.horizontalAccuracy);

	// Altitude
	CLLocationDistance altitude = location.altitude;
	if (!isnan(altitude)) {
		gps[(NSString *)kCGImagePropertyGPSAltitudeRef] = (altitude < 0) ? @(1) : @(0);
		gps[(NSString *)kCGImagePropertyGPSAltitude] = @(fabs(altitude));
	}

	// Speed, must be converted from m/s to km/h
	if (location.speed >= 0) {
		gps[(NSString *)kCGImagePropertyGPSSpeedRef] = @"K";
		gps[(NSString *)kCGImagePropertyGPSSpeed] = @(location.speed * (3600.0/1000.0));
	}

	// Direction of movement
	if (location.course >= 0) {
		gps[(NSString *)kCGImagePropertyGPSTrackRef] = @"T";
		gps[(NSString *)kCGImagePropertyGPSTrack] = @(location.course);
	}

	// Direction the device is pointing
	gps[(NSString *)kCGImagePropertyGPSHPositioningError] = @(heading.headingAccuracy);
	if (heading.headingAccuracy >= 0.0) {
		if (heading.trueHeading >= 0.0) {
			gps[(NSString *)kCGImagePropertyGPSImgDirectionRef] = @"T";
			gps[(NSString *)kCGImagePropertyGPSImgDirection] = @(heading.trueHeading);
		} else {
			// Only magnetic heading is available
			gps[(NSString *)kCGImagePropertyGPSImgDirectionRef] = @"M";
			gps[(NSString *)kCGImagePropertyGPSImgDirection] = @(heading.magneticHeading);
		}
	}

	// TODO: Add support for the following properties

	// Destination Bearing

	// Destination Bearing Reference

	return gps;
}

- (NSDictionary *)MotionDictionaryFor:(CMDeviceMotion*)motion
{
	NSMutableDictionary *motionDict = [NSMutableDictionary dictionary];

	// Attitude (pitch, roll, yaw)
	motionDict[@"attitude"] = [NSMutableDictionary dictionary];
	motionDict[@"attitude"][@"roll"] = @(motion.attitude.roll);
	motionDict[@"attitude"][@"pitch"] = @(motion.attitude.pitch);
	motionDict[@"attitude"][@"yaw"] = @(motion.attitude.yaw);

	// Rotation Rate (x, y, z)
	motionDict[@"rotationRate"] = [NSMutableDictionary dictionary];
	motionDict[@"rotationRate"][@"x"] = @(motion.rotationRate.x);
	motionDict[@"rotationRate"][@"y"] = @(motion.rotationRate.y);
	motionDict[@"rotationRate"][@"z"] = @(motion.rotationRate.z);

	// Gravity (x, y, z)
	motionDict[@"gravity"] = [NSMutableDictionary dictionary];
	motionDict[@"gravity"][@"x"] = @(motion.gravity.x);
	motionDict[@"gravity"][@"y"] = @(motion.gravity.y);
	motionDict[@"gravity"][@"z"] = @(motion.gravity.z);

	// User Acceleration (x, y, z)
	motionDict[@"userAcceleration"] = [NSMutableDictionary dictionary];
	motionDict[@"userAcceleration"][@"x"] = @(motion.userAcceleration.x);
	motionDict[@"userAcceleration"][@"y"] = @(motion.userAcceleration.y);
	motionDict[@"userAcceleration"][@"z"] = @(motion.userAcceleration.z);

	// Magnetic Field (x, y, z)
	motionDict[@"magneticField"] = [NSMutableDictionary dictionary];
	motionDict[@"magneticField"][@"x"] = @(motion.magneticField.field.x);
	motionDict[@"magneticField"][@"y"] = @(motion.magneticField.field.y);
	motionDict[@"magneticField"][@"z"] = @(motion.magneticField.field.z);
	motionDict[@"magneticField"][@"accuracy"] = @(motion.magneticField.accuracy);

	// Heading
	motionDict[@"heading"] = @(motion.heading);

	// Sensor Location
	if (@available(iOS 14.0, *)) {
		motionDict[@"sensorLocation"] = @(motion.sensorLocation);
	}

	return motionDict;
}

- (nullable NSDictionary<NSString *, id> *)replacementMetadataForPhoto:(AVCapturePhoto *)photo
{

	NSMutableDictionary *metaData = [photo.metadata mutableCopy];

	if ([CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedWhenInUse ||
		[CLLocationManager authorizationStatus] == kCLAuthorizationStatusAuthorizedAlways) {
		CLLocation *location = [_locationManager location];
		CLHeading *heading = [_locationManager heading];
		[metaData setObject:[self GPSDictionaryForLocation:location heading:heading]
					 forKey:(NSString*)kCGImagePropertyGPSDictionary];
	}

	self.metaData = metaData;
	// NSLog(@"%@",self.metaData);

	return metaData;
}

- (nullable NSDictionary<NSString *, id> *)extendedMetadataForPhoto:(AVCapturePhoto *)photo
{
	NSMutableDictionary *metaData = [photo.metadata mutableCopy];

	CMDeviceMotion *motion = [_motionManager deviceMotion];
	[metaData setObject:[self MotionDictionaryFor:motion] forKey:@"{DeviceMotion}"];

	// Add a depth data embedded key
	[metaData setObject:(photo.depthData != nil)?@(YES):@(NO) forKey:@"DepthDataEmbedded"];

	return metaData;
}

//- (AVDepthData *)replacementDepthDataForPhoto:(AVCapturePhoto *)photo
//{
//	NSLog(@"Camera: Depth Data: %@",photo.depthData);
//	_containsDepthData = (photo.depthData != nil);
//	return photo.depthData;
//}

//- (void)captureOutput:(AVCapturePhotoOutput *)output
//didFinishProcessingPhoto:(AVCapturePhoto *)photo
//				error:(NSError *)error {
//
//	[self handlePhotoCaptureResultWithError:error
//						  photoDataProvider:^NSData * {
//		return [photo fileDataRepresentationWithCustomizer:self];
//	}
//								   metaData:nil];
//}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
				error:(NSError *)error {

	[self handlePhotoCaptureResultWithError:error
									  photo:photo
								   metaData:nil];
}

@end
