import "dart:io" as io;

bool get hostIsIOS => io.Platform.isIOS;

bool get hostIsAndroid => io.Platform.isAndroid;

String get hostOperatingSystem => io.Platform.operatingSystem;

String get hostOperatingSystemVersion => io.Platform.operatingSystemVersion;
