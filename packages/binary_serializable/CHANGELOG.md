## 0.4.0

- Support `binary_serializable_generator ^0.5.0`

## 0.3.6

- Update metadata to point to dart-community GitHub organization.

## 0.3.5

- Use `getSubtype` when decoding values.

## 0.3.4

- Add a fallback `getSubtype` function to `MultiBinaryType`.

## 0.3.3

- Fix issue with buffers losing their lengths in some conversions.

## 0.3.2

- Introduce new `BinaryType.encodeInto` method for efficient encoding. Existing `BinaryType` implementations must now implement this method instead of `encode`.

## 0.3.1

- Bump dependencies.

## 0.3.0

- Fix a bug in CompositeBinaryConversion causing the input buffer to not be consumed properly.
- Allow subconverters in CompositeBinaryConversion to call onValue without consuming any data.
- Add MultiBinaryConversion.
- Add missing const constructors.

## 0.2.2

- Change default endianess for numeric types to big endian.

## 0.2.1

- Allow 0-length conversions.

## 0.2.0

- Added `BufferType`, `BufferConversion` and `CompositeBinaryConversion`

## 0.1.0

- Initial version.
