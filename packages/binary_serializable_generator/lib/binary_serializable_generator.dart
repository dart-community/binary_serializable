import 'package:binary_serializable_generator/src/binary_serializable_generator.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

Builder createBuilder(BuilderOptions options) => SharedPartBuilder(
      [BinarySerializableGenerator()],
      'binary_serializable',
    );
