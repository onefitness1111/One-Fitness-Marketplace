import "dart:io";
import "dart:typed_data";

Future<Uint8List> readLocalBytes(String path) => File(path).readAsBytes();
