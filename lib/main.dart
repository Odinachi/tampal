import 'package:flutter/foundation.dart';
import 'main_desktop.dart' as desktop;
import 'main_mobile.dart' as mobile;
import 'main_web.dart' as web;

void main() {
  if (kIsWeb) {
    web.main();
  } else if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    mobile.main();
  } else {
    desktop.main();
  }
}
