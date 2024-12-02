import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:binary_serializable/binary_serializable.dart';
import 'package:build/build.dart';
import 'package:code_builder/code_builder.dart'
    hide Block, FunctionType, RecordType, Expression;
import 'package:code_builder/code_builder.dart' as code_builder
    show Block, FunctionType, RecordType, Expression;
import 'package:source_gen/source_gen.dart';

/// Information about a serialized field in a class.
class FieldInformation {
  final String name;
  final code_builder.Expression binaryType;
  final Reference dartType;
  final bool isInPrelude;

  FieldInformation({
    required this.name,
    required this.binaryType,
    required this.dartType,
    required this.isInPrelude,
  });

  @override
  String toString() => name;
}

const binarySerializableUri =
    'package:binary_serializable/src/binary_serializable.dart';
const binaryTypeUrl = 'package:binary_serializable/src/binary_type.dart';

const binarySerializable =
    TypeChecker.fromUrl('$binarySerializableUri#BinarySerializable');

const generic = TypeChecker.fromUrl('$binarySerializableUri#Generic');

const binaryType = TypeChecker.fromUrl('$binaryTypeUrl#BinaryType');

class BinarySerializableGenerator
    extends GeneratorForAnnotation<BinarySerializable> {
  @override
  Future<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) async {
    final node = await buildStep.resolver.astNodeFor(element, resolve: true);

    if (node is! ClassDeclaration) {
      throw '${element.name}: @BinarySerializable() may only be applied to classes';
    }

    if (node.abstractKeyword != null) {
      return await BinarySerializableEmitter(buildStep).generateMultiType(node);
    }

    final constructor =
        node.members.whereType<ConstructorDeclaration>().firstOrNull;

    return await BinarySerializableEmitter(buildStep)
        .generateType(node, constructor);
  }
}

class BinarySerializableEmitter {
  final BuildStep buildStep;

  BinarySerializableEmitter(this.buildStep);

  Future<List<FieldInformation>> getFields(ClassDeclaration node) async {
    final element = node.declaredElement!;

    final fields = <FieldInformation>[];

    // Superclass fields always go first to support preludes.
    for (final supertype in [
      if (element.supertype case final supertype?) supertype,
      ...element.mixins,
      ...element.interfaces,
    ]) {
      final superclass = supertype.element;

      if (binarySerializable.firstAnnotationOf(superclass) != null) {
        if (fields.isNotEmpty) {
          throw '${element.name} cannot implement more than one BinarySerializable type';
        }

        final superclassNode =
            await buildStep.resolver.astNodeFor(superclass, resolve: true);

        final substitutions = <String, Reference>{};
        final typeParametersInScope = <String>[];

        for (int i = 0; i < superclass.typeParameters.length; i++) {
          final parameter = superclass.typeParameters[i];
          final argument = supertype.typeArguments[i];

          substitutions[parameter.name] = argument.toReference();
          typeParametersInScope.add(parameter.name);
        }

        final superclassFields =
            await getFields(superclassNode as ClassDeclaration);

        final substitutedSuperclassFields = superclassFields.map(
          (field) => FieldInformation(
            name: field.name,
            binaryType: rewriteGenericExpressions(
              field.binaryType,
              (genericExpression) => GenericExpression(
                genericExpression.genericType.rewriteGenerics(
                    typeParametersInScope, (p) => substitutions[p]!),
              ),
            ).$1,
            dartType: field.dartType.rewriteGenerics(
                typeParametersInScope, (p) => substitutions[p]!),
            isInPrelude: field.isInPrelude,
          ),
        );

        fields.addAll(substitutedSuperclassFields);
      }
    }

    final orderedFields = [
      ...node.members.whereType<FieldDeclaration>(),
      ...node.members.whereType<MethodDeclaration>().where((m) => m.isGetter),
    ]..sort((a, b) => a.offset.compareTo(b.offset));

    for (final field in orderedFields) {
      final fieldName = field is MethodDeclaration
          ? field.name.lexeme
          : (field as FieldDeclaration).fields.variables.first.name.lexeme;

      Annotation? binaryTypeAnnotation;
      bool wasComputed = false;
      for (final annotation in field.metadata) {
        final value = annotation.elementAnnotation?.computeConstantValue();
        final type = value?.type;
        if (value == null || type == null) {
          // Tentatively assume the error was due to referencing a
          // yet-ungenerated BinaryType.
          binaryTypeAnnotation ??= annotation;
        } else if (binaryType.isAssignableFromType(type)) {
          if (wasComputed) {
            throw '${element.name}.$fieldName cannot have more than one BinaryType annotation';
          } else {
            wasComputed = true;
            binaryTypeAnnotation = annotation;
          }
        }
      }

      if (binaryTypeAnnotation == null) {
        continue;
      }

      final List<Declaration> subfields = field is MethodDeclaration
          ? [field]
          : (field as FieldDeclaration).fields.variables;

      for (final subfield in subfields) {
        final fieldName = subfield.declaredElement!.name!;

        final existingIndex = fields
            .indexWhere((existingField) => existingField.name == fieldName);

        final fieldInformation = FieldInformation(
          name: fieldName,
          binaryType: binaryTypeAnnotation.toExpression(),
          dartType: (field is MethodDeclaration
                  ? field.returnType!.type!
                  : (field as FieldDeclaration).fields.type!.type!)
              .toReference(),
          isInPrelude: field is MethodDeclaration,
        );

        if (existingIndex != -1) {
          fields[existingIndex] = fieldInformation;
        } else {
          fields.add(fieldInformation);
        }
      }
    }

    return fields;
  }

  Future<String> generateType(
    ClassDeclaration clazz,
    ConstructorDeclaration? constructor,
  ) async {
    final element = clazz.declaredElement!;
    final fields = await getFields(clazz);

    final typeParameters = element.typeParameters.map((p) => p.toReference());
    final typeArguments = element.typeParameters
        .map((p) => TypeReference((builder) => builder..symbol = p.name));
    final targetType = TypeReference(
      (builder) => builder
        ..symbol = element.name
        ..types.replace(typeArguments),
    );

    final typeName = '${element.name}Type';

    final conversionName = element.isPrivate
        ? '${element.name}Conversion'
        : '_${element.name}Conversion';

    final genericAllocations = <Reference, String>{};

    final constructorFields = fields
        .where(
          (f) =>
              constructor?.parameters.parameters
                  .any((p) => p.name!.lexeme == f.name) ??
              false,
        )
        .toList();
    final predeterminedFields =
        fields.where((f) => !constructorFields.contains(f)).toList();

    var instanceVariableName = 'instance';
    while (fields.any((f) => f.name == instanceVariableName)) {
      instanceVariableName = '_$instanceVariableName';
    }

    code_builder.Expression constructorReference = targetType;
    if (constructor?.name case final name?) {
      constructorReference = constructorReference.property(name.lexeme);
    }

    final onValueReference = fields.any((f) => f.name == 'onValue')
        ? refer('this').property('onValue')
        : refer('onValue');

    final typeReference = fields.any((f) => f.name == 'type')
        ? refer('this').property('type')
        : refer('type');

    Code startConversionBody = code_builder.Block.of([
      declareFinal(instanceVariableName)
          .assign(
            constructorReference.call(
              constructor?.parameters.parameters
                      .where((p) => !p.isNamed)
                      .map((p) => refer(p.name!.lexeme)) ??
                  [],
              Map.fromEntries(
                constructor?.parameters.parameters.where((p) => p.isNamed).map(
                        (p) =>
                            MapEntry(p.name!.lexeme, refer(p.name!.lexeme))) ??
                    [],
              ),
            ),
          )
          .statement,
      for (final field in predeterminedFields) Code('''
    if ($instanceVariableName.${field.name} != ${field.name}) {
      throw 'parsed field ${field.name} does not match predefined value';
    }
'''),
      onValueReference.call([refer(instanceVariableName)]).statement,
    ]);

    for (final field in fields.reversed) {
      final newConversion = rewriteGenericExpressions(
        field.binaryType,
        (generic) => typeReference.property(
            genericAllocations[generic.genericType] ??=
                'genericType${generic.name ?? genericAllocations.length}'),
      ).$1.property('startConversion').call([
        Method(
          (builder) => builder
            ..requiredParameters.replace([
              Parameter(
                (builder) => builder..name = field.name,
              ),
            ])
            ..body = startConversionBody,
        ).closure,
      ]);

      if (field == fields.first) {
        startConversionBody = newConversion.returned.statement;
      } else {
        startConversionBody =
            refer('currentConversion').assign(newConversion).statement;
      }
    }

    final conversion = Class(
      (builder) => builder
        ..name = conversionName
        ..types.replace(typeParameters)
        ..extend = TypeReference(
          (type) => type
            ..symbol = fields.isNotEmpty
                ? 'CompositeBinaryConversion'
                : 'BinaryConversion'
            ..types.replace([targetType]),
        )
        ..fields.replace([
          Field(
            (builder) => builder
              ..modifier = FieldModifier.final$
              ..type = TypeReference(
                (builder) => builder
                  ..symbol = typeName
                  ..types.replace(typeArguments),
              )
              ..name = 'type',
          ),
        ])
        ..constructors.replace([
          Constructor(
            (builder) => builder
              ..requiredParameters.replace([
                Parameter((builder) => builder
                  ..toThis = true
                  ..name = 'type'),
                Parameter((builder) => builder
                  ..toSuper = true
                  ..name = 'onValue'),
              ]),
          )
        ])
        ..methods.replace([
          if (fields.isNotEmpty)
            Method(
              (builder) => builder
                ..annotations.replace([refer('override')])
                ..returns = refer('BinaryConversion')
                ..name = 'startConversion'
                ..body = startConversionBody,
            )
          else ...[
            Method(
              (builder) => builder
                ..annotations.replace([refer('override')])
                ..returns = refer('int')
                ..name = 'add'
                ..requiredParameters.replace([
                  Parameter(
                    (builder) => builder
                      ..name = 'data'
                      ..type = refer('Uint8List'),
                  )
                ])
                ..body = code_builder.Block(
                  (builder) => builder
                    ..statements.add(startConversionBody)
                    ..statements.add(literal(0).returned.statement),
                ),
            ),
            Method(
              (builder) => builder
                ..annotations.replace([refer('override')])
                ..returns = refer('void')
                ..name = 'flush'
                ..body = code_builder.Block(),
            )
          ]
        ]),
    );

    final type = Class(
      (builder) => builder
        ..name = typeName
        ..types.replace(typeParameters)
        ..extend = TypeReference(
          (type) => type
            ..symbol = 'BinaryType'
            ..types.replace([targetType]),
        )
        ..fields.replace([
          for (final MapEntry(:key, :value) in genericAllocations.entries)
            Field(
              (builder) => builder
                ..modifier = FieldModifier.final$
                ..type = TypeReference(
                  (builder) => builder
                    ..symbol = 'BinaryType'
                    ..types.replace([key]),
                )
                ..name = value,
            ),
        ])
        ..constructors.replace([
          Constructor((builder) => builder
            ..constant = true
            ..requiredParameters.replace([
              for (final genericFieldName in genericAllocations.values)
                Parameter(
                  (builder) => builder
                    ..toThis = true
                    ..name = genericFieldName,
                ),
            ]))
        ])
        ..methods.replace([
          Method(
            (builder) => builder
              ..annotations.replace([refer('override')])
              ..returns = refer('void')
              ..name = 'encodeInto'
              ..requiredParameters.replace([
                Parameter(
                  (builder) => builder
                    ..type = targetType
                    ..name = 'input',
                ),
                Parameter(
                  (builder) => builder
                    ..type = refer('BytesBuilder')
                    ..name = 'builder',
                ),
              ])
              ..body = code_builder.Block(
                (builder) => builder.statements.replace([
                  for (final field in fields)
                    rewriteGenericExpressions(
                      field.binaryType,
                      (generic) =>
                          refer(genericAllocations[generic.genericType]!),
                    ).$1.property('encodeInto').call([
                      refer('input').property(field.name),
                      refer('builder'),
                    ]).statement,
                ]),
              ),
          ),
          Method(
            (builder) => builder
              ..annotations.replace([
                refer('override'),
              ])
              ..returns = TypeReference(
                (builder) => builder
                  ..symbol = 'BinaryConversion'
                  ..types.replace([targetType]),
              )
              ..name = 'startConversion'
              ..requiredParameters.replace([
                Parameter(
                  (builder) => builder
                    ..type = code_builder.FunctionType(
                      (builder) => builder
                        ..returnType = refer('void')
                        ..requiredParameters.replace([targetType]),
                    )
                    ..name = 'onValue',
                ),
              ])
              ..body = InvokeExpression.newOf(
                refer(conversionName),
                [refer('this'), refer('onValue')],
              ).code,
          ),
        ]),
    );

    final emitter = DartEmitter(useNullSafetySyntax: true);
    final sink = StringBuffer();

    type.accept(emitter, sink);
    conversion.accept(emitter, sink);

    return sink.toString();
  }

  Future<Map<code_builder.Expression, code_builder.Expression>> getSubtypes(
    List<FieldInformation> preludeFields,
    ClassElement clazz,
    LibraryElement inLibrary,
  ) async {
    final accessibleElements = [
      ...inLibrary.topLevelElements,
      ...inLibrary.importedLibraries
          .expand((library) => library.exportNamespace.definedNames.values),
    ];

    final result = <code_builder.Expression, code_builder.Expression>{};
    for (final element in accessibleElements) {
      if (element is! ClassElement) continue;
      if (binarySerializable.annotationsOf(element).isEmpty) continue;

      if (element.supertype != clazz.thisType &&
          !element.mixins.contains(clazz.thisType) &&
          !element.interfaces.contains(clazz.thisType)) {
        continue;
      }

      result.addAll(await getSubtype(preludeFields, element, inLibrary));
    }

    return result;
  }

  Future<Map<code_builder.Expression, code_builder.Expression>> getSubtype(
    List<FieldInformation> preludeFields,
    ClassElement clazz,
    LibraryElement inLibrary,
  ) async {
    if (clazz.typeParameters.isEmpty) {
      var hasCompletePrelude = true;
      final preludeExpressions = <code_builder.Expression>[];
      for (final field in preludeFields) {
        final implementation =
            clazz.thisType.lookUpGetter2(field.name, inLibrary);

        if (implementation == null ||
            implementation.isSynthetic ||
            implementation.isAbstract) {
          hasCompletePrelude = false;
          break;
        }

        final node =
            await buildStep.resolver.astNodeFor(implementation, resolve: true);

        if (node is! MethodDeclaration ||
            node.body is! ExpressionFunctionBody) {
          hasCompletePrelude = false;
          break;
        }

        final expression =
            (node.body as ExpressionFunctionBody).expression.toExpression();

        preludeExpressions.add(expression);
      }

      if (hasCompletePrelude) {
        final typeInstanciation = refer('${clazz.name}Type').call([]);

        if (preludeExpressions.length == 1) {
          return {
            preludeExpressions.single: typeInstanciation,
          };
        }

        return {
          CodeExpression(Code('')).call(preludeExpressions): typeInstanciation,
        };
      }
    }

    return await getSubtypes(preludeFields, clazz, inLibrary);
  }

  Future<String> generateMultiType(ClassDeclaration clazz) async {
    final element = clazz.declaredElement!;
    final fields = await getFields(clazz);

    final preludeFields = fields.where((f) => f.isInPrelude).toList();

    final typeParameters = element.typeParameters.map((p) => p.toReference());
    final typeArguments = element.typeParameters
        .map((p) => TypeReference((builder) => builder..symbol = p.name));
    final targetType = TypeReference((builder) => builder
      ..symbol = element.name
      ..types.replace(typeArguments));
    final preludeType = preludeFields.length == 1
        ? preludeFields.single.dartType
        : code_builder.RecordType(
            (builder) => builder
              ..positionalFieldTypes.replace([
                for (final field in preludeFields) field.dartType,
              ]),
          );

    final typeName = '${element.name}Type';

    final conversionName = element.isPrivate
        ? '${element.name}PreludeConversion'
        : '_${element.name}PreludeConversion';

    final onValueReference = fields.any((f) => f.name == 'onValue')
        ? refer('this').property('onValue')
        : refer('onValue');

    final typeReference = fields.any((f) => f.name == 'type')
        ? refer('this').property('type')
        : refer('type');

    final genericAllocations = <Reference, String>{};

    Code startConversionBody = onValueReference.call([
      preludeFields.length == 1
          ? refer(preludeFields.single.name)
          : CodeExpression(Code('')).call([
              for (final field in preludeFields) refer(field.name),
            ]),
    ]).statement;

    for (final field in fields.reversed) {
      final newConversion = rewriteGenericExpressions(
        field.binaryType,
        (generic) => typeReference.property(
            genericAllocations[generic.genericType] ??=
                'genericType${generic.name ?? genericAllocations.length}'),
      ).$1.property('startConversion').call([
        Method(
          (builder) => builder
            ..requiredParameters.replace([
              Parameter(
                (builder) => builder..name = field.name,
              ),
            ])
            ..body = startConversionBody,
        ).closure,
      ]);

      if (field == fields.first) {
        startConversionBody = newConversion.returned.statement;
      } else {
        startConversionBody =
            refer('currentConversion').assign(newConversion).statement;
      }
    }

    final conversion = Class(
      (builder) => builder
        ..name = conversionName
        ..types.replace(typeParameters)
        ..extend = TypeReference(
          (builder) => builder
            ..symbol = 'CompositeBinaryConversion'
            ..types.replace([preludeType]),
        )
        ..fields.replace([
          Field(
            (builder) => builder
              ..modifier = FieldModifier.final$
              ..type = refer(typeName)
              ..name = 'type',
          ),
        ])
        ..constructors.replace([
          Constructor(
            (builder) => builder
              ..requiredParameters.replace([
                Parameter(
                  (builder) => builder
                    ..toThis = true
                    ..name = 'type',
                ),
                Parameter(
                  (builder) => builder
                    ..toSuper = true
                    ..name = 'onValue',
                ),
              ]),
          ),
        ])
        ..methods.replace([
          Method(
            (builder) => builder
              ..annotations.replace([refer('override')])
              ..returns = refer('BinaryConversion')
              ..name = 'startConversion'
              ..body = startConversionBody,
          )
        ]),
    );

    final subtypes = await getSubtypes(
      preludeFields,
      element,
      element.library,
    );

    final type = Class(
      (builder) => builder
        ..name = typeName
        ..types.replace(typeParameters)
        ..extend = TypeReference(
          (builder) => builder
            ..symbol = 'MultiBinaryType'
            ..types.replace([targetType, preludeType]),
        )
        ..fields.replace([
          if (typeArguments.isEmpty)
            Field(
              (builder) => builder
                ..static = true
                ..modifier = FieldModifier.constant
                ..name = 'defaultSubtypes'
                ..type = TypeReference((builder) => builder
                  ..symbol = 'Map'
                  ..types.replace([
                    preludeType,
                    TypeReference(
                      (builder) => builder
                        ..symbol = 'BinaryType'
                        ..types.replace([targetType]),
                    ),
                  ]))
                ..assignment = literalConstMap(subtypes).code,
            ),
          for (final MapEntry(:key, :value) in genericAllocations.entries)
            Field(
              (builder) => builder
                ..modifier = FieldModifier.final$
                ..type = TypeReference(
                  (builder) => builder
                    ..symbol = 'BinaryType'
                    ..types.replace([key]),
                )
                ..name = value,
            ),
        ])
        ..constructors.replace([
          Constructor(
            (builder) => builder
              ..constant = true
              ..requiredParameters.replace([
                for (final genericFieldName in genericAllocations.values)
                  Parameter(
                    (builder) => builder
                      ..toThis = true
                      ..name = genericFieldName,
                  ),
              ])
              ..optionalParameters.replace([
                Parameter(
                  (builder) => builder
                    ..named = true
                    ..toSuper = true
                    ..name = 'subtypes'
                    ..defaultTo = typeArguments.isEmpty
                        ? refer(typeName).property('defaultSubtypes').code
                        : literalConstMap({}).code,
                ),
                Parameter(
                  (builder) => builder
                    ..named = true
                    ..toSuper = true
                    ..name = 'getSubtype',
                ),
              ]),
          )
        ])
        ..methods.replace([
          Method(
            (builder) => builder
              ..annotations.replace([refer('override')])
              ..returns = preludeType
              ..name = 'extractPrelude'
              ..requiredParameters.replace([
                Parameter(
                  (builder) => builder
                    ..type = targetType
                    ..name = 'instance',
                ),
              ])
              ..body = preludeFields.length == 1
                  ? refer('instance').property(preludeFields.single.name).code
                  : CodeExpression(Code('')).call([
                      for (final field in preludeFields)
                        refer('instance').property(field.name),
                    ]).code,
          ),
          Method(
            (builder) => builder
              ..annotations.replace([refer('override')])
              ..returns = TypeReference(
                (builder) => builder
                  ..symbol = 'BinaryConversion'
                  ..types.replace([preludeType]),
              )
              ..name = 'startPreludeConversion'
              ..requiredParameters.replace([
                Parameter(
                  (builder) => builder
                    ..type = code_builder.FunctionType(
                      (builder) => builder
                        ..returnType = refer('void')
                        ..requiredParameters.replace([preludeType]),
                    )
                    ..name = 'onValue',
                ),
              ])
              ..body = InvokeExpression.newOf(
                refer(conversionName),
                [refer('this'), refer('onValue')],
              ).code,
          ),
        ]),
    );

    final buffer = StringBuffer();
    final emitter = DartEmitter();

    type.accept(emitter, buffer);
    conversion.accept(emitter, buffer);

    return buffer.toString();
  }
}

extension on TypeParameterElement {
  TypeReference toReference() => TypeReference((builder) {
        builder.symbol = name;
        if (bound case final bound?) {
          builder.bound = bound.toReference();
        }
      });
}

extension on DartType {
  Reference toReference() => switch (this) {
        InterfaceType type => TypeReference(
            (builder) => builder
              ..symbol = type.element.name
              ..types.replace(type.typeArguments.map((t) => t.toReference()))
              ..isNullable = type.nullabilitySuffix != NullabilitySuffix.none,
          ),
        FunctionType type => code_builder.FunctionType(
            (builder) => builder
              ..returnType = type.returnType.toReference()
              ..types.replace(type.typeFormals.map((p) => p.toReference()))
              ..requiredParameters.replace(
                type.parameters
                    .where((p) => p.isRequiredPositional)
                    .map((p) => p.type.toReference()),
              )
              ..optionalParameters.replace(
                type.parameters
                    .where((p) => p.isOptionalPositional)
                    .map((p) => p.type.toReference()),
              )
              ..namedParameters.addEntries(
                (type.parameters)
                    .where((p) => p.isOptionalNamed)
                    .map((p) => MapEntry(p.name, p.type.toReference())),
              )
              ..namedRequiredParameters.addEntries(
                (type.parameters)
                    .where((p) => p.isRequiredNamed)
                    .map((p) => MapEntry(p.name, p.type.toReference())),
              )
              ..isNullable = type.nullabilitySuffix != NullabilitySuffix.none,
          ),
        RecordType type => code_builder.RecordType(
            (builder) => builder
              ..positionalFieldTypes.replace(
                type.positionalFields.map((f) => f.type.toReference()),
              )
              ..namedFieldTypes.addEntries(
                type.namedFields
                    .map((f) => MapEntry(f.name, f.type.toReference())),
              )
              ..isNullable = type.nullabilitySuffix != NullabilitySuffix.none,
          ),
        TypeParameterType type => TypeReference(
            (builder) => builder..symbol = type.element.name,
          ),
        DynamicType() => refer('dynamic'),
        VoidType() => refer('void'),
        NeverType() => refer('Never'),
        InvalidType() || _ => throw 'Cannot reference $this',
      };
}

extension on Expression {
  code_builder.Expression toExpression() => switch (this) {
        SimpleIdentifier node =>
          refer(node.name, node.staticElement?.source?.uri.toString()),
        Literal node => CodeExpression(Code(node.toSource())),
        InstanceCreationExpression node
            when node.constructorName.staticElement?.enclosingElement3.name ==
                'Generic' =>
          GenericExpression.forGenericName(
              (node.argumentList.arguments.first as StringLiteral)
                  .stringValue!),
        InstanceCreationExpression node => InvokeExpression.newOf(
            node.constructorName.toExpression(),
            node.argumentList.arguments
                .where((e) => e is! NamedExpression)
                .map((e) => e.toExpression())
                .toList(),
            Map.fromEntries(
              node.argumentList.arguments.whereType<NamedExpression>().map(
                  (e) =>
                      MapEntry(e.name.label.name, e.expression.toExpression())),
            ),
          ),
        InvocationExpression node => InvokeExpression.newOf(
            node.function.toExpression(),
            node.argumentList.arguments
                .where((e) => e is! NamedExpression)
                .map((e) => e.toExpression())
                .toList(),
            Map.fromEntries(
              node.argumentList.arguments.whereType<NamedExpression>().map(
                  (e) =>
                      MapEntry(e.name.label.name, e.expression.toExpression())),
            ),
          ),
        _ => throw 'Unable to reconstruct expression $this',
      };
}

extension on Annotation {
  code_builder.Expression toExpression() {
    final arguments = this.arguments;
    if (arguments == null) {
      return name.toExpression();
    }

    if (name.name == 'Generic') {
      return GenericExpression.forGenericName(
          (arguments.arguments.first as StringLiteral).stringValue!);
    }

    var constructor = name.toExpression();
    if (constructorName case SimpleIdentifier(:final name)) {
      constructor = constructor.property(name);
    }

    return InvokeExpression.newOf(
      constructor,
      arguments.arguments
          .where((e) => e is! NamedExpression)
          .map((e) => e.toExpression())
          .toList(),
      Map.fromEntries(
        arguments.arguments.whereType<NamedExpression>().map(
            (e) => MapEntry(e.name.label.name, e.expression.toExpression())),
      ),
    );
  }
}

extension on ConstructorName {
  code_builder.Expression toExpression() {
    code_builder.Expression result = type.type!.toReference();
    if (name case SimpleIdentifier(:final name)) {
      result = result.property(name);
    }
    return result;
  }
}

(code_builder.Expression, bool isConst) rewriteGenericExpressions(
  code_builder.Expression expression,
  code_builder.Expression Function(GenericExpression) replace,
) =>
    switch (expression) {
      GenericExpression() => (replace(expression), false),
      CodeExpression() => (expression, true),
      Reference() => (expression, true),
      InvokeExpression() => () {
          bool isConst = true;

          final rewrittenPositionalArguments = <code_builder.Expression>[];
          for (final argument in expression.positionalArguments) {
            final (rewritten, isConst2) =
                rewriteGenericExpressions(argument, replace);

            rewrittenPositionalArguments.add(rewritten);
            isConst &= isConst2;
          }

          final rewrittenNamedArguments = <String, code_builder.Expression>{};
          for (final MapEntry(:key, :value)
              in expression.namedArguments.entries) {
            final (rewritten, isConst2) =
                rewriteGenericExpressions(value, replace);

            rewrittenNamedArguments[key] = rewritten;
            isConst &= isConst2;
          }

          final factory =
              isConst ? InvokeExpression.constOf : InvokeExpression.newOf;

          return (
            factory(
              expression.target,
              rewrittenPositionalArguments,
              rewrittenNamedArguments,
            ),
            isConst,
          );
        }(),
      _ => throw "",
    };

extension on Reference {
  Reference rewriteGenerics(
    List<String> typeParametersInScope,
    Reference Function(String) replace,
  ) =>
      switch (this) {
        Reference(:final symbol?) when typeParametersInScope.contains(symbol) =>
          replace(symbol),
        code_builder.FunctionType type => code_builder.FunctionType(
            (builder) => builder
              ..isNullable = type.isNullable
              ..namedParameters
                  .replace(type.namedParameters.map((k, v) => MapEntry(
                        k,
                        v.rewriteGenerics(typeParametersInScope, replace),
                      )))
              ..namedRequiredParameters
                  .replace(type.namedRequiredParameters.map((k, v) => MapEntry(
                        k,
                        v.rewriteGenerics(typeParametersInScope, replace),
                      )))
              ..optionalParameters.replace(type.optionalParameters
                  .map((p) => p.rewriteGenerics(typeParametersInScope, replace))
                  .toList())
              ..requiredParameters.replace(type.requiredParameters
                  .map((p) => p.rewriteGenerics(typeParametersInScope, replace))
                  .toList())
              ..returnType = type.returnType
                  ?.rewriteGenerics(typeParametersInScope, replace)
              ..symbol = type.symbol
              ..types.replace(type.types
                  .map((t) => t.rewriteGenerics(typeParametersInScope, replace))
                  .toList())
              ..url = type.url,
          ),
        code_builder.RecordType type => code_builder.RecordType(
            (builder) => builder
              ..isNullable = type.isNullable
              ..namedFieldTypes.replace(type.namedFieldTypes.map((k, v) =>
                  MapEntry(
                      k, v.rewriteGenerics(typeParametersInScope, replace))))
              ..positionalFieldTypes.replace(type.positionalFieldTypes
                  .map((t) => t.rewriteGenerics(typeParametersInScope, replace))
                  .toList())
              ..symbol = type.symbol
              ..url = type.url,
          ),
        TypeReference type => TypeReference(
            (builder) => builder
              ..isNullable = type.isNullable
              ..symbol = type.symbol
              ..types.replace(type.types
                  .map((t) => t.rewriteGenerics(typeParametersInScope, replace))
                  .toList())
              ..url = type.url,
          ),
        Reference() => this,
      };
}

class GenericExpression extends code_builder.Expression {
  final Reference genericType;
  final String? name;

  GenericExpression(this.genericType) : name = null;

  GenericExpression.forGenericName(String this.name)
      : genericType = refer(name);

  @override
  R accept<R>(covariant ExpressionVisitor<R> visitor, [R? context]) {
    throw UnimplementedError();
  }
}
