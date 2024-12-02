import 'package:binary_serializable/binary_serializable.dart';

part 'example.g.dart';

@BinarySerializable()
class Example {
  @uint64
  final int id;

  @utf8String
  final String name;

  @LengthPrefixedListType(uint8, utf8String)
  final List<String> tags;

  Example(this.id, this.name, this.tags);
}

@BinarySerializable()
class GenericType<T, U> {
  @Generic('T')
  final T genericField;

  @LengthPrefixedListType(uint8, Generic('U'))
  final List<U> genericList;

  GenericType(this.genericField, this.genericList);
}

@BinarySerializable()
abstract class Message {
  @uint8
  int get id;
}

@BinarySerializable()
class StringMessage extends Message {
  @override
  int get id => 2;

  @utf8String
  final String data;

  StringMessage(this.data);
}

@BinarySerializable()
class IntegerMessage extends Message {
  @override
  int get id => 1;

  @int64
  final int data;

  IntegerMessage(this.data);
}

@BinarySerializable()
class Empty {}
