// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'example.dart';

// **************************************************************************
// BinarySerializableGenerator
// **************************************************************************

class ExampleType extends BinaryType<Example> {
  const ExampleType();

  @override
  void encodeInto(
    Example input,
    BytesBuilder builder,
  ) {
    uint64.encodeInto(
      input.id,
      builder,
    );
    utf8String.encodeInto(
      input.name,
      builder,
    );
    const LengthPrefixedListType(
      uint8,
      utf8String,
    ).encodeInto(
      input.tags,
      builder,
    );
  }

  @override
  BinaryConversion<Example> startConversion(void Function(Example) onValue) =>
      _ExampleConversion(
        this,
        onValue,
      );
}

class _ExampleConversion extends CompositeBinaryConversion<Example> {
  _ExampleConversion(
    this.type,
    super.onValue,
  );

  final ExampleType type;

  @override
  BinaryConversion startConversion() {
    return uint64.startConversion((id) {
      currentConversion = utf8String.startConversion((name) {
        currentConversion = const LengthPrefixedListType(
          uint8,
          utf8String,
        ).startConversion((tags) {
          final instance = Example(
            id,
            name,
            tags,
          );
          onValue(instance);
        });
      });
    });
  }
}

class GenericTypeType<T, U> extends BinaryType<GenericType<T, U>> {
  const GenericTypeType(
    this.genericTypeU,
    this.genericTypeT,
  );

  final BinaryType<U> genericTypeU;

  final BinaryType<T> genericTypeT;

  @override
  void encodeInto(
    GenericType<T, U> input,
    BytesBuilder builder,
  ) {
    genericTypeT.encodeInto(
      input.genericField,
      builder,
    );
    LengthPrefixedListType(
      uint8,
      genericTypeU,
    ).encodeInto(
      input.genericList,
      builder,
    );
  }

  @override
  BinaryConversion<GenericType<T, U>> startConversion(
          void Function(GenericType<T, U>) onValue) =>
      _GenericTypeConversion(
        this,
        onValue,
      );
}

class _GenericTypeConversion<T, U>
    extends CompositeBinaryConversion<GenericType<T, U>> {
  _GenericTypeConversion(
    this.type,
    super.onValue,
  );

  final GenericTypeType<T, U> type;

  @override
  BinaryConversion startConversion() {
    return type.genericTypeT.startConversion((genericField) {
      currentConversion = LengthPrefixedListType(
        uint8,
        type.genericTypeU,
      ).startConversion((genericList) {
        final instance = GenericType<T, U>(
          genericField,
          genericList,
        );
        onValue(instance);
      });
    });
  }
}

class MessageType extends MultiBinaryType<Message, int> {
  const MessageType({
    super.subtypes = MessageType.defaultSubtypes,
    super.getSubtype,
  });

  static const Map<int, BinaryType<Message>> defaultSubtypes = {
    2: StringMessageType(),
    1: IntegerMessageType(),
  };

  @override
  int extractPrelude(Message instance) => instance.id;

  @override
  BinaryConversion<int> startPreludeConversion(void Function(int) onValue) =>
      _MessagePreludeConversion(
        this,
        onValue,
      );
}

class _MessagePreludeConversion extends CompositeBinaryConversion<int> {
  _MessagePreludeConversion(
    this.type,
    super.onValue,
  );

  final MessageType type;

  @override
  BinaryConversion startConversion() {
    return uint8.startConversion((id) {
      onValue(id);
    });
  }
}

class StringMessageType extends BinaryType<StringMessage> {
  const StringMessageType();

  @override
  void encodeInto(
    StringMessage input,
    BytesBuilder builder,
  ) {
    uint8.encodeInto(
      input.id,
      builder,
    );
    utf8String.encodeInto(
      input.data,
      builder,
    );
  }

  @override
  BinaryConversion<StringMessage> startConversion(
          void Function(StringMessage) onValue) =>
      _StringMessageConversion(
        this,
        onValue,
      );
}

class _StringMessageConversion
    extends CompositeBinaryConversion<StringMessage> {
  _StringMessageConversion(
    this.type,
    super.onValue,
  );

  final StringMessageType type;

  @override
  BinaryConversion startConversion() {
    return uint8.startConversion((id) {
      currentConversion = utf8String.startConversion((data) {
        final instance = StringMessage(data);
        if (instance.id != id) {
          throw 'parsed field id does not match predefined value';
        }

        onValue(instance);
      });
    });
  }
}

class IntegerMessageType extends BinaryType<IntegerMessage> {
  const IntegerMessageType();

  @override
  void encodeInto(
    IntegerMessage input,
    BytesBuilder builder,
  ) {
    uint8.encodeInto(
      input.id,
      builder,
    );
    int64.encodeInto(
      input.data,
      builder,
    );
  }

  @override
  BinaryConversion<IntegerMessage> startConversion(
          void Function(IntegerMessage) onValue) =>
      _IntegerMessageConversion(
        this,
        onValue,
      );
}

class _IntegerMessageConversion
    extends CompositeBinaryConversion<IntegerMessage> {
  _IntegerMessageConversion(
    this.type,
    super.onValue,
  );

  final IntegerMessageType type;

  @override
  BinaryConversion startConversion() {
    return uint8.startConversion((id) {
      currentConversion = int64.startConversion((data) {
        final instance = IntegerMessage(data);
        if (instance.id != id) {
          throw 'parsed field id does not match predefined value';
        }

        onValue(instance);
      });
    });
  }
}

class EmptyType extends BinaryType<Empty> {
  const EmptyType();

  @override
  void encodeInto(
    Empty input,
    BytesBuilder builder,
  ) {}
  @override
  BinaryConversion<Empty> startConversion(void Function(Empty) onValue) =>
      _EmptyConversion(
        this,
        onValue,
      );
}

class _EmptyConversion extends BinaryConversion<Empty> {
  _EmptyConversion(
    this.type,
    super.onValue,
  );

  final EmptyType type;

  @override
  int add(Uint8List data) {
    final instance = Empty();
    onValue(instance);
    return 0;
  }

  @override
  void flush() {}
}
