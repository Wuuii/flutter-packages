// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

/// The direction the camera is facing.
enum CameraLensDirection {
  /// Front facing camera (a user looking at the screen is seen by the camera).
  front,

  /// Back facing camera (a user looking at the screen is not seen by the camera).
  back,

  /// External camera which may not be mounted to the device.
  external,
}

/// Properties of a camera device.
@immutable
class CameraDescription {
  /// Creates a new camera description with the given properties.
  const CameraDescription({
    required this.name,
    required this.localizedName,
    required this.fov,
    required this.fovDepth,
    required this.maxZoomFactor,
    required this.depthSupported,
    required this.lensDirection,
    required this.sensorOrientation,
  });

  /// The name of the camera device.
  final String name;

  /// The localized name of the camera device.
  /// This is the name that should be displayed to the user.
  final String localizedName;

  /// The field of view for the active camera format
  final double fov;

  // The field of view for the active depth camera format
  final double fovDepth;

  /// The maximum zoom factor for the active camera format
  final double maxZoomFactor;

  /// Whether the camera supports depth data
  final bool depthSupported;

  /// The direction the camera is facing.
  final CameraLensDirection lensDirection;

  /// Clockwise angle through which the output image needs to be rotated to be upright on the device screen in its native orientation.
  ///
  /// **Range of valid values:**
  /// 0, 90, 180, 270
  ///
  /// On Android, also defines the direction of rolling shutter readout, which
  /// is from top to bottom in the sensor's coordinate system.
  final int sensorOrientation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CameraDescription &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          lensDirection == other.lensDirection &&
          fov == other.fov &&
          depthSupported == other.depthSupported;

  @override
  int get hashCode => Object.hash(name, lensDirection);

  @override
  String toString() {
    return '${objectRuntimeType(this, 'CameraDescription')}('
        '$name, $localizedName, $fov, $fovDepth, $maxZoomFactor, $depthSupported, $lensDirection, $sensorOrientation)';
  }
}
