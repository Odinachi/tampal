import 'dart:io';
import 'package:flutter/foundation.dart';
import 'main_desktop.dart' as desktop;
import 'main_mobile.dart' as mobile;

void main() {
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    mobile.main();
  } else {
    desktop.main();
  }
}
