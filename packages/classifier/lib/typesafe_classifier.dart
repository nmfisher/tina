/// Typesafe HTTP transport for structured judgments.
///
/// Splits the network-bound `TypeSafeService` and `TypeSafeConfig` away
/// from the pure `judgments.dart` surface so judgment consumers can stay
/// free of `dart:io` and `package:http`.
library;

export 'src/judgments/typesafe_service.dart';
