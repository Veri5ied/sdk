// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.kernel_target;

import 'dart:async' show Future;

import 'package:kernel/ast.dart'
    show
        Arguments,
        CanonicalName,
        Class,
        Component,
        Constructor,
        DartType,
        EmptyStatement,
        Expression,
        Field,
        FieldInitializer,
        FunctionNode,
        Initializer,
        InterfaceType,
        InvalidInitializer,
        InvalidType,
        Library,
        Name,
        NamedExpression,
        NullLiteral,
        Procedure,
        RedirectingInitializer,
        Source,
        SuperInitializer,
        Supertype,
        TypeParameter,
        TypeParameterType,
        VariableDeclaration,
        VariableGet;

import 'package:kernel/class_hierarchy.dart' show ClassHierarchy;

import 'package:kernel/clone.dart' show CloneVisitorNotMembers;

import 'package:kernel/core_types.dart';

import 'package:kernel/reference_from_index.dart' show IndexedClass;

import 'package:kernel/type_algebra.dart' show substitute;
import 'package:kernel/target/changed_structure_notifier.dart'
    show ChangedStructureNotifier;
import 'package:kernel/target/targets.dart' show DiagnosticReporter;
import 'package:kernel/type_environment.dart' show TypeEnvironment;
import 'package:kernel/verifier.dart' show verifyGetStaticType;

import '../../api_prototype/file_system.dart' show FileSystem;

import '../builder/builder.dart';
import '../builder/class_builder.dart';
import '../builder/dynamic_type_builder.dart';
import '../builder/field_builder.dart';
import '../builder/invalid_type_declaration_builder.dart';
import '../builder/library_builder.dart';
import '../builder/named_type_builder.dart';
import '../builder/never_type_builder.dart';
import '../builder/nullability_builder.dart';
import '../builder/procedure_builder.dart';
import '../builder/type_alias_builder.dart';
import '../builder/type_builder.dart';
import '../builder/type_declaration_builder.dart';
import '../builder/type_variable_builder.dart';
import '../builder/void_type_builder.dart';

import '../compiler_context.dart' show CompilerContext;

import '../crash.dart' show withCrashReporting;

import '../dill/dill_target.dart' show DillTarget;

import '../dill/dill_member_builder.dart' show DillMemberBuilder;

import '../fasta_codes.dart' show Message, LocatedMessage;

import '../loader.dart' show Loader;

import '../messages.dart'
    show
        FormattedMessage,
        messageConstConstructorLateFinalFieldCause,
        messageConstConstructorLateFinalFieldError,
        messageConstConstructorLateFinalFieldWarning,
        messageConstConstructorNonFinalField,
        messageConstConstructorNonFinalFieldCause,
        messageConstConstructorRedirectionToNonConst,
        noLength,
        templateFieldNonNullableNotInitializedByConstructorError,
        templateFieldNonNullableNotInitializedByConstructorWarning,
        templateFieldNonNullableWithoutInitializerError,
        templateFieldNonNullableWithoutInitializerWarning,
        templateFinalFieldNotInitialized,
        templateFinalFieldNotInitializedByConstructor,
        templateInferredPackageUri,
        templateMissingImplementationCause,
        templateSuperclassHasNoDefaultConstructor;

import '../problems.dart' show unhandled;

import '../scope.dart' show AmbiguousBuilder;

import '../source/source_class_builder.dart' show SourceClassBuilder;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import '../source/source_loader.dart' show SourceLoader;

import '../target_implementation.dart' show TargetImplementation;

import '../uri_translator.dart' show UriTranslator;

import 'constant_evaluator.dart' as constants
    show EvaluationMode, transformLibraries;

import 'kernel_constants.dart' show KernelConstantErrorReporter;

import 'metadata_collector.dart' show MetadataCollector;

import 'verifier.dart' show verifyComponent;

class KernelTarget extends TargetImplementation {
  /// The [FileSystem] which should be used to access files.
  final FileSystem fileSystem;

  /// Whether comments should be scanned and parsed.
  final bool includeComments;

  final DillTarget dillTarget;

  /// The [MetadataCollector] to write metadata to.
  final MetadataCollector metadataCollector;

  SourceLoader loader;

  Component component;

  // 'dynamic' is always nullable.
  final TypeBuilder dynamicType = new NamedTypeBuilder(
      "dynamic", const NullabilityBuilder.nullable(), null);

  final NamedTypeBuilder objectType =
      new NamedTypeBuilder("Object", const NullabilityBuilder.omitted(), null);

  // Null is always nullable.
  final TypeBuilder bottomType =
      new NamedTypeBuilder("Null", const NullabilityBuilder.nullable(), null);

  final bool excludeSource = !CompilerContext.current.options.embedSourceText;

  final Map<String, String> environmentDefines =
      CompilerContext.current.options.environmentDefines;

  final bool errorOnUnevaluatedConstant =
      CompilerContext.current.options.errorOnUnevaluatedConstant;

  final List<Object> clonedFormals = <Object>[];

  KernelTarget(this.fileSystem, this.includeComments, DillTarget dillTarget,
      UriTranslator uriTranslator,
      {MetadataCollector metadataCollector})
      : dillTarget = dillTarget,
        metadataCollector = metadataCollector,
        super(dillTarget.ticker, uriTranslator, dillTarget.backendTarget) {
    loader = createLoader();
  }

  SourceLoader createLoader() =>
      new SourceLoader(fileSystem, includeComments, this);

  void addSourceInformation(
      Uri importUri, Uri fileUri, List<int> lineStarts, List<int> sourceCode) {
    uriToSource[fileUri] =
        new Source(lineStarts, sourceCode, importUri, fileUri);
  }

  /// Return list of same size as input with possibly translated uris.
  List<Uri> setEntryPoints(List<Uri> entryPoints) {
    Map<String, Uri> packagesMap;
    List<Uri> result = new List<Uri>();
    for (Uri entryPoint in entryPoints) {
      packagesMap ??= uriTranslator.packages.asMap();
      Uri translatedEntryPoint = getEntryPointUri(entryPoint,
          packagesMap: packagesMap, issueProblem: true);
      result.add(translatedEntryPoint);
      loader.read(translatedEntryPoint, -1,
          accessor: loader.first,
          fileUri: translatedEntryPoint != entryPoint ? entryPoint : null);
    }
    return result;
  }

  /// Return list of same size as input with possibly translated uris.
  Uri getEntryPointUri(Uri entryPoint,
      {Map<String, Uri> packagesMap, bool issueProblem: false}) {
    String scheme = entryPoint.scheme;
    switch (scheme) {
      case "package":
      case "dart":
      case "data":
        break;
      default:
        // Attempt to reverse-lookup [entryPoint] in package config.
        String asString = "$entryPoint";
        packagesMap ??= uriTranslator.packages.asMap();
        for (String packageName in packagesMap.keys) {
          Uri packageUri = packagesMap[packageName];
          if (packageUri?.hasFragment == true) {
            packageUri = packageUri.removeFragment();
          }
          String prefix = "${packageUri}";
          if (asString.startsWith(prefix)) {
            Uri reversed = Uri.parse(
                "package:$packageName/${asString.substring(prefix.length)}");
            if (entryPoint == uriTranslator.translate(reversed)) {
              if (issueProblem) {
                loader.addProblem(
                    templateInferredPackageUri.withArguments(reversed),
                    -1,
                    1,
                    entryPoint);
              }
              entryPoint = reversed;
              break;
            }
          }
        }
    }
    return entryPoint;
  }

  @override
  LibraryBuilder createLibraryBuilder(
      Uri uri,
      Uri fileUri,
      SourceLibraryBuilder origin,
      Library referencesFrom,
      bool referenceIsPartOwner) {
    if (dillTarget.isLoaded) {
      LibraryBuilder builder = dillTarget.loader.builders[uri];
      if (builder != null) {
        return builder;
      }
    }
    return new SourceLibraryBuilder(uri, fileUri, loader, origin,
        referencesFrom: referencesFrom,
        referenceIsPartOwner: referenceIsPartOwner);
  }

  /// Returns classes defined in libraries in [loader].
  List<SourceClassBuilder> collectMyClasses() {
    List<SourceClassBuilder> result = <SourceClassBuilder>[];
    loader.builders.forEach((Uri uri, LibraryBuilder library) {
      if (library.loader == loader) {
        Iterator<Builder> iterator = library.iterator;
        while (iterator.moveNext()) {
          Builder member = iterator.current;
          if (member is SourceClassBuilder && !member.isPatch) {
            result.add(member);
          }
        }
      }
    });
    return result;
  }

  void breakCycle(ClassBuilder builder) {
    Class cls = builder.cls;
    cls.implementedTypes.clear();
    cls.supertype = null;
    cls.mixedInType = null;
    builder.supertype =
        new NamedTypeBuilder("Object", const NullabilityBuilder.omitted(), null)
          ..bind(objectClassBuilder);
    builder.interfaces = null;
    builder.mixedInType = null;
  }

  @override
  Future<Component> buildOutlines({CanonicalName nameRoot}) async {
    if (loader.first == null) return null;
    return withCrashReporting<Component>(() async {
      await loader.buildOutlines();
      loader.createTypeInferenceEngine();
      loader.coreLibrary.becomeCoreLibrary();
      dynamicType.bind(
          loader.coreLibrary.lookupLocalMember("dynamic", required: true));
      loader.resolveParts();
      loader.computeLibraryScopes();
      setupTopAndBottomTypes();
      loader.resolveTypes();
      loader.computeVariances();
      loader.computeDefaultTypes(dynamicType, bottomType, objectClassBuilder);
      List<SourceClassBuilder> myClasses =
          loader.checkSemantics(objectClassBuilder);
      loader.finishTypeVariables(objectClassBuilder, dynamicType);
      loader.buildComponent();
      installDefaultSupertypes();
      installSyntheticConstructors(myClasses);
      loader.resolveConstructors();
      component =
          link(new List<Library>.from(loader.libraries), nameRoot: nameRoot);
      computeCoreTypes();
      loader.buildClassHierarchy(myClasses, objectClassBuilder);
      loader.computeHierarchy();
      loader.performTopLevelInference(myClasses);
      loader.checkSupertypes(myClasses);
      loader.checkTypes();
      loader.checkOverrides(myClasses);
      loader.checkAbstractMembers(myClasses);
      loader.checkRedirectingFactories(myClasses);
      loader.addNoSuchMethodForwarders(myClasses);
      loader.checkMixins(myClasses);
      loader.buildOutlineExpressions(loader.coreTypes);
      _updateDelayedParameterTypes();
      installAllComponentProblems(loader.allComponentProblems);
      loader.allComponentProblems.clear();
      return component;
    }, () => loader?.currentUriForCrashReporting);
  }

  /// Build the kernel representation of the component loaded by this
  /// target. The component will contain full bodies for the code loaded from
  /// sources, and only references to the code loaded by the [DillTarget],
  /// which may or may not include method bodies (depending on what was loaded
  /// into that target, an outline or a full kernel component).
  ///
  /// If [verify], run the default kernel verification on the resulting
  /// component.
  @override
  Future<Component> buildComponent({bool verify: false}) async {
    if (loader.first == null) return null;
    return withCrashReporting<Component>(() async {
      ticker.logMs("Building component");
      await loader.buildBodies();
      finishClonedParameters();
      loader.finishDeferredLoadTearoffs();
      loader.finishNoSuchMethodForwarders();
      List<SourceClassBuilder> myClasses = collectMyClasses();
      loader.finishNativeMethods();
      loader.finishPatchMethods();
      finishAllConstructors(myClasses);
      runBuildTransformations();

      if (verify) this.verify();
      installAllComponentProblems(loader.allComponentProblems);
      return component;
    }, () => loader?.currentUriForCrashReporting);
  }

  void installAllComponentProblems(
      List<FormattedMessage> allComponentProblems) {
    if (allComponentProblems.isNotEmpty) {
      component.problemsAsJson ??= <String>[];
    }
    for (int i = 0; i < allComponentProblems.length; i++) {
      FormattedMessage formattedMessage = allComponentProblems[i];
      component.problemsAsJson.add(formattedMessage.toJsonString());
    }
  }

  /// Creates a component by combining [libraries] with the libraries of
  /// `dillTarget.loader.component`.
  Component link(List<Library> libraries, {CanonicalName nameRoot}) {
    libraries.addAll(dillTarget.loader.libraries);

    Map<Uri, Source> uriToSource = new Map<Uri, Source>();
    void copySource(Uri uri, Source source) {
      uriToSource[uri] = excludeSource
          ? new Source(source.lineStarts, const <int>[], source.importUri,
              source.fileUri)
          : source;
    }

    this.uriToSource.forEach(copySource);

    Component component = backendTarget.configureComponent(new Component(
        nameRoot: nameRoot, libraries: libraries, uriToSource: uriToSource));
    if (loader.first != null) {
      // TODO(sigmund): do only for full program
      Builder declaration = loader.first.exportScope.lookup("main", -1, null);
      if (declaration is AmbiguousBuilder) {
        AmbiguousBuilder problem = declaration;
        declaration = problem.getFirstDeclaration();
      }
      if (declaration is ProcedureBuilder) {
        component.mainMethod = declaration.actualProcedure;
      } else if (declaration is DillMemberBuilder) {
        if (declaration.member is Procedure) {
          component.mainMethod = declaration.member;
        }
      }
    }

    if (metadataCollector != null) {
      component.addMetadataRepository(metadataCollector.repository);
    }

    ticker.logMs("Linked component");
    return component;
  }

  void installDefaultSupertypes() {
    Class objectClass = this.objectClass;
    loader.builders.forEach((Uri uri, LibraryBuilder library) {
      if (library.loader == loader) {
        Iterator<Builder> iterator = library.iterator;
        while (iterator.moveNext()) {
          Builder declaration = iterator.current;
          if (declaration is SourceClassBuilder) {
            Class cls = declaration.cls;
            if (cls != objectClass) {
              cls.supertype ??= objectClass.asRawSupertype;
              declaration.supertype ??= new NamedTypeBuilder(
                  "Object", const NullabilityBuilder.omitted(), null)
                ..bind(objectClassBuilder);
            }
            if (declaration.isMixinApplication) {
              cls.mixedInType = declaration.mixedInType.buildMixedInType(
                  library, declaration.charOffset, declaration.fileUri);
            }
          }
        }
      }
    });
    ticker.logMs("Installed Object as implicit superclass");
  }

  void installSyntheticConstructors(List<SourceClassBuilder> builders) {
    Class objectClass = this.objectClass;
    for (SourceClassBuilder builder in builders) {
      if (builder.cls != objectClass && !builder.isPatch) {
        if (builder.isPatch ||
            builder.isMixinDeclaration ||
            builder.isExtension) {
          continue;
        }
        if (builder.isMixinApplication) {
          installForwardingConstructors(builder);
        } else {
          installDefaultConstructor(builder);
        }
      }
    }
    ticker.logMs("Installed synthetic constructors");
  }

  List<DelayedParameterType> _delayedParameterTypes = <DelayedParameterType>[];

  /// Update the type of parameters cloned from parameters with inferred
  /// parameter types.
  void _updateDelayedParameterTypes() {
    for (DelayedParameterType delayedParameterType in _delayedParameterTypes) {
      delayedParameterType.updateType();
    }
    _delayedParameterTypes.clear();
  }

  ClassBuilder get objectClassBuilder => objectType.declaration;

  Class get objectClass => objectClassBuilder.cls;

  /// If [builder] doesn't have a constructors, install the defaults.
  void installDefaultConstructor(SourceClassBuilder builder) {
    assert(!builder.isMixinApplication);
    assert(!builder.isExtension);
    // TODO(askesc): Make this check light-weight in the absence of patches.
    if (builder.cls.constructors.isNotEmpty) return;
    if (builder.cls.redirectingFactoryConstructors.isNotEmpty) return;
    for (Procedure proc in builder.cls.procedures) {
      if (proc.isFactory) return;
    }

    IndexedClass indexedClass = builder.referencesFromIndexed;
    Constructor referenceFrom;
    if (indexedClass != null) {
      referenceFrom = indexedClass.lookupConstructor("");
    }

    /// From [Dart Programming Language Specification, 4th Edition](
    /// https://ecma-international.org/publications/files/ECMA-ST/ECMA-408.pdf):
    /// >Iff no constructor is specified for a class C, it implicitly has a
    /// >default constructor C() : super() {}, unless C is class Object.
    // The superinitializer is installed below in [finishConstructors].
    builder.addSyntheticConstructor(
        makeDefaultConstructor(builder.cls, referenceFrom));
  }

  void installForwardingConstructors(SourceClassBuilder builder) {
    assert(builder.isMixinApplication);
    if (builder.library.loader != loader) return;
    if (builder.cls.constructors.isNotEmpty) {
      // These were installed by a subclass in the recursive call below.
      return;
    }

    /// From [Dart Programming Language Specification, 4th Edition](
    /// https://ecma-international.org/publications/files/ECMA-ST/ECMA-408.pdf):
    /// >A mixin application of the form S with M; defines a class C with
    /// >superclass S.
    /// >...

    /// >Let LM be the library in which M is declared. For each generative
    /// >constructor named qi(Ti1 ai1, . . . , Tiki aiki), i in 1..n of S
    /// >that is accessible to LM , C has an implicitly declared constructor
    /// >named q'i = [C/S]qi of the form q'i(ai1,...,aiki) :
    /// >super(ai1,...,aiki);.
    TypeBuilder type = builder.supertype;
    TypeDeclarationBuilder supertype;
    if (type is NamedTypeBuilder) {
      supertype = type.declaration;
    } else {
      unhandled("${type.runtimeType}", "installForwardingConstructors",
          builder.charOffset, builder.fileUri);
    }
    if (supertype is TypeAliasBuilder) {
      TypeAliasBuilder aliasBuilder = supertype;
      supertype = aliasBuilder.unaliasDeclaration;
    }
    if (supertype is SourceClassBuilder && supertype.isMixinApplication) {
      installForwardingConstructors(supertype);
    }

    IndexedClass indexedClass = builder.referencesFromIndexed;
    Constructor referenceFrom;
    if (indexedClass != null) {
      referenceFrom = indexedClass.lookupConstructor("");
    }

    if (supertype is ClassBuilder) {
      if (supertype.cls.constructors.isEmpty) {
        builder.addSyntheticConstructor(
            makeDefaultConstructor(builder.cls, referenceFrom));
      } else {
        Map<TypeParameter, DartType> substitutionMap =
            builder.getSubstitutionMap(supertype.cls);
        for (Constructor constructor in supertype.cls.constructors) {
          Constructor referenceFrom =
              indexedClass?.lookupConstructor(constructor.name.name);

          builder.addSyntheticConstructor(makeMixinApplicationConstructor(
              builder.cls,
              builder.cls.mixin,
              constructor,
              substitutionMap,
              referenceFrom));
        }
      }
    } else if (supertype is InvalidTypeDeclarationBuilder ||
        supertype is TypeVariableBuilder ||
        supertype is DynamicTypeBuilder ||
        supertype is VoidTypeBuilder ||
        supertype is NeverTypeBuilder) {
      builder.addSyntheticConstructor(
          makeDefaultConstructor(builder.cls, referenceFrom));
    } else {
      unhandled("${supertype.runtimeType}", "installForwardingConstructors",
          builder.charOffset, builder.fileUri);
    }
  }

  Constructor makeMixinApplicationConstructor(
      Class cls,
      Class mixin,
      Constructor constructor,
      Map<TypeParameter, DartType> substitutionMap,
      Constructor referenceFrom) {
    VariableDeclaration copyFormal(VariableDeclaration formal) {
      // TODO(ahe): Handle initializers.
      VariableDeclaration copy = new VariableDeclaration(formal.name,
          isFinal: formal.isFinal, isConst: formal.isConst);
      if (formal.type != null) {
        copy.type = substitute(formal.type, substitutionMap);
      } else {
        _delayedParameterTypes
            .add(new DelayedParameterType(formal, copy, substitutionMap));
      }
      return copy;
    }

    List<VariableDeclaration> positionalParameters = <VariableDeclaration>[];
    List<VariableDeclaration> namedParameters = <VariableDeclaration>[];
    List<Expression> positional = <Expression>[];
    List<NamedExpression> named = <NamedExpression>[];
    for (VariableDeclaration formal
        in constructor.function.positionalParameters) {
      positionalParameters.add(copyFormal(formal));
      positional.add(new VariableGet(positionalParameters.last));
    }
    for (VariableDeclaration formal in constructor.function.namedParameters) {
      VariableDeclaration clone = copyFormal(formal);
      clonedFormals..add(formal)..add(clone)..add(substitutionMap);
      namedParameters.add(clone);
      named.add(new NamedExpression(
          formal.name, new VariableGet(namedParameters.last)));
    }
    FunctionNode function = new FunctionNode(new EmptyStatement(),
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        requiredParameterCount: constructor.function.requiredParameterCount,
        returnType: makeConstructorReturnType(cls));
    SuperInitializer initializer = new SuperInitializer(
        constructor, new Arguments(positional, named: named));
    return new Constructor(function,
        name: constructor.name,
        initializers: <Initializer>[initializer],
        isSynthetic: true,
        isConst: constructor.isConst && mixin.fields.isEmpty,
        reference: referenceFrom?.reference);
  }

  void finishClonedParameters() {
    for (int i = 0; i < clonedFormals.length; i += 3) {
      // Note that [original] may itself be clone. If so, it was added to
      // [clonedFormals] before [clone], so it's initializers are already in
      // place.
      VariableDeclaration original = clonedFormals[i];
      VariableDeclaration clone = clonedFormals[i + 1];
      if (original.initializer != null) {
        // TODO(ahe): It is unclear if it is legal to use type variables in
        // default values, but Fasta is currently allowing it, and the VM
        // accepts it. If it isn't legal, the we can speed this up by using a
        // single cloner without substitution.
        CloneVisitorNotMembers cloner =
            new CloneVisitorNotMembers(typeSubstitution: clonedFormals[i + 2]);
        clone.initializer = cloner.clone(original.initializer)..parent = clone;
      }
    }
    clonedFormals.clear();
    ticker.logMs("Cloned default values of formals");
  }

  Constructor makeDefaultConstructor(
      Class enclosingClass, Constructor referenceFrom) {
    return new Constructor(
        new FunctionNode(new EmptyStatement(),
            returnType: makeConstructorReturnType(enclosingClass)),
        name: new Name(""),
        isSynthetic: true,
        reference: referenceFrom?.reference);
  }

  DartType makeConstructorReturnType(Class enclosingClass) {
    List<DartType> typeParameterTypes = new List<DartType>();
    for (int i = 0; i < enclosingClass.typeParameters.length; i++) {
      TypeParameter typeParameter = enclosingClass.typeParameters[i];
      typeParameterTypes.add(
          new TypeParameterType.withDefaultNullabilityForLibrary(
              typeParameter, enclosingClass.enclosingLibrary));
    }
    return new InterfaceType(enclosingClass,
        enclosingClass.enclosingLibrary.nonNullable, typeParameterTypes);
  }

  void setupTopAndBottomTypes() {
    objectType
        .bind(loader.coreLibrary.lookupLocalMember("Object", required: true));

    ClassBuilder nullClassBuilder =
        loader.coreLibrary.lookupLocalMember("Null", required: true);
    nullClassBuilder.isNullClass = true;
    bottomType.bind(nullClassBuilder);
  }

  void computeCoreTypes() {
    List<Library> libraries = <Library>[];
    for (String platformLibrary in [
      "dart:_internal",
      "dart:async",
      "dart:core",
      "dart:mirrors",
      ...backendTarget.extraIndexedLibraries
    ]) {
      Uri uri = Uri.parse(platformLibrary);
      LibraryBuilder libraryBuilder = loader.builders[uri];
      if (libraryBuilder == null) {
        // TODO(ahe): This is working around a bug in kernel_driver_test or
        // kernel_driver.
        bool found = false;
        for (Library target in dillTarget.loader.libraries) {
          if (target.importUri == uri) {
            libraries.add(target);
            found = true;
            break;
          }
        }
        if (!found && uri.path != "mirrors") {
          // dart:mirrors is optional.
          throw "Can't find $uri";
        }
      } else {
        libraries.add(libraryBuilder.library);
      }
    }
    Component platformLibraries =
        backendTarget.configureComponent(new Component());
    // Add libraries directly to prevent that their parents are changed.
    platformLibraries.libraries.addAll(libraries);
    loader.computeCoreTypes(platformLibraries);
  }

  void finishAllConstructors(List<SourceClassBuilder> builders) {
    Class objectClass = this.objectClass;
    for (SourceClassBuilder builder in builders) {
      Class cls = builder.cls;
      if (cls != objectClass) {
        finishConstructors(builder);
      }
    }
    ticker.logMs("Finished constructors");
  }

  /// Ensure constructors of [builder] have the correct initializers and other
  /// requirements.
  void finishConstructors(SourceClassBuilder builder) {
    if (builder.isPatch) return;
    Class cls = builder.cls;

    /// Quotes below are from [Dart Programming Language Specification, 4th
    /// Edition](http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-408.pdf):
    List<Field> uninitializedFields = <Field>[];
    for (Field field in cls.fields) {
      if (field.initializer == null) {
        uninitializedFields.add(field);
      }
    }
    List<FieldBuilder> nonFinalFields = <FieldBuilder>[];
    List<FieldBuilder> lateFinalFields = <FieldBuilder>[];
    builder.forEach((String name, Builder fieldBuilder) {
      if (fieldBuilder is FieldBuilder) {
        if (fieldBuilder.isDeclarationInstanceMember && !fieldBuilder.isFinal) {
          nonFinalFields.add(fieldBuilder);
        }
        if (fieldBuilder.isDeclarationInstanceMember &&
            fieldBuilder.isLate &&
            fieldBuilder.isFinal) {
          lateFinalFields.add(fieldBuilder);
        }
      }
    });
    Map<Constructor, Set<Field>> constructorInitializedFields =
        <Constructor, Set<Field>>{};
    Constructor superTarget;
    for (Constructor constructor in cls.constructors) {
      bool isRedirecting = false;
      for (Initializer initializer in constructor.initializers) {
        if (initializer is RedirectingInitializer) {
          if (constructor.isConst && !initializer.target.isConst) {
            builder.addProblem(messageConstConstructorRedirectionToNonConst,
                initializer.fileOffset, initializer.target.name.name.length);
          }
          isRedirecting = true;
          break;
        }
      }
      if (!isRedirecting) {
        /// >If no superinitializer is provided, an implicit superinitializer
        /// >of the form super() is added at the end of k’s initializer list,
        /// >unless the enclosing class is class Object.
        if (constructor.initializers.isEmpty) {
          superTarget ??= defaultSuperConstructor(cls);
          Initializer initializer;
          if (superTarget == null) {
            int offset = constructor.fileOffset;
            if (offset == -1 && constructor.isSynthetic) {
              offset = cls.fileOffset;
            }
            builder.addProblem(
                templateSuperclassHasNoDefaultConstructor
                    .withArguments(cls.superclass.name),
                offset,
                noLength);
            initializer = new InvalidInitializer();
          } else {
            initializer =
                new SuperInitializer(superTarget, new Arguments.empty())
                  ..isSynthetic = true;
          }
          constructor.initializers.add(initializer);
          initializer.parent = constructor;
        }
        if (constructor.function.body == null) {
          /// >If a generative constructor c is not a redirecting constructor
          /// >and no body is provided, then c implicitly has an empty body {}.
          /// We use an empty statement instead.
          constructor.function.body = new EmptyStatement();
          constructor.function.body.parent = constructor.function;
        }

        Set<Field> myInitializedFields = new Set<Field>();
        for (Initializer initializer in constructor.initializers) {
          if (initializer is FieldInitializer) {
            myInitializedFields.add(initializer.field);
          }
        }
        for (VariableDeclaration formal
            in constructor.function.positionalParameters) {
          if (formal.isFieldFormal) {
            Builder fieldBuilder =
                builder.scope.lookupLocalMember(formal.name, setter: false) ??
                    builder.origin.scope
                        .lookupLocalMember(formal.name, setter: false);
            // If next is not null it's a duplicated field,
            // and it doesn't need to be initialized to null below
            // (and doing it will crash serialization).
            if (fieldBuilder?.next == null && fieldBuilder is FieldBuilder) {
              myInitializedFields.add(fieldBuilder.field);
            }
          }
        }
        constructorInitializedFields[constructor] = myInitializedFields;
        if (constructor.isConst && nonFinalFields.isNotEmpty) {
          builder.addProblem(messageConstConstructorNonFinalField,
              constructor.fileOffset, noLength,
              context: nonFinalFields
                  .map((field) => messageConstConstructorNonFinalFieldCause
                      .withLocation(field.fileUri, field.charOffset, noLength))
                  .toList());
          nonFinalFields.clear();
        }
        SourceLibraryBuilder library = builder.library;
        if (library.isNonNullableByDefault &&
            library.loader.performNnbdChecks) {
          if (constructor.isConst && lateFinalFields.isNotEmpty) {
            if (library.loader.nnbdStrongMode) {
              builder.addProblem(messageConstConstructorLateFinalFieldError,
                  constructor.fileOffset, noLength,
                  context: lateFinalFields
                      .map((field) => messageConstConstructorLateFinalFieldCause
                          .withLocation(
                              field.fileUri, field.charOffset, noLength))
                      .toList());
              lateFinalFields.clear();
            } else {
              builder.addProblem(messageConstConstructorLateFinalFieldWarning,
                  constructor.fileOffset, noLength,
                  context: lateFinalFields
                      .map((field) => messageConstConstructorLateFinalFieldCause
                          .withLocation(
                              field.fileUri, field.charOffset, noLength))
                      .toList());
              lateFinalFields.clear();
            }
          }
        }
      }
    }
    Set<Field> initializedFields;
    constructorInitializedFields
        .forEach((Constructor constructor, Set<Field> fields) {
      if (initializedFields == null) {
        initializedFields = new Set<Field>.from(fields);
      } else {
        initializedFields.addAll(fields);
      }
    });

    // Run through all fields that aren't initialized by any constructor, and
    // set their initializer to `null`.
    for (Field field in uninitializedFields) {
      if (initializedFields == null || !initializedFields.contains(field)) {
        if (!field.isLate) {
          field.initializer = new NullLiteral()..parent = field;
          if (field.isFinal &&
              (cls.constructors.isNotEmpty || cls.isMixinDeclaration)) {
            String uri = '${field.enclosingLibrary.importUri}';
            String file = field.fileUri.pathSegments.last;
            if (uri == 'dart:html' ||
                uri == 'dart:svg' ||
                uri == 'dart:_native_typed_data' ||
                uri == 'dart:_interceptors' && file == 'js_string.dart') {
              // TODO(johnniwinther): Use external getters instead of final
              // fields. See https://github.com/dart-lang/sdk/issues/33762
            } else {
              builder.library.addProblem(
                  templateFinalFieldNotInitialized
                      .withArguments(field.name.name),
                  field.fileOffset,
                  field.name.name.length,
                  field.fileUri);
            }
          } else if (field.type is! InvalidType &&
              field.type.isPotentiallyNonNullable &&
              (cls.constructors.isNotEmpty || cls.isMixinDeclaration)) {
            SourceLibraryBuilder library = builder.library;
            if (library.isNonNullableByDefault &&
                library.loader.performNnbdChecks) {
              if (library.loader.nnbdStrongMode) {
                library.addProblem(
                    templateFieldNonNullableWithoutInitializerError
                        .withArguments(field.name.name, field.type,
                            library.isNonNullableByDefault),
                    field.fileOffset,
                    field.name.name.length,
                    library.fileUri);
              } else {
                library.addProblem(
                    templateFieldNonNullableWithoutInitializerWarning
                        .withArguments(field.name.name, field.type,
                            library.isNonNullableByDefault),
                    field.fileOffset,
                    field.name.name.length,
                    library.fileUri);
              }
            }
          }
        }
      }
    }

    // Run through all fields that are initialized by some constructor, and
    // make sure that all other constructors also initialize them.
    constructorInitializedFields
        .forEach((Constructor constructor, Set<Field> fields) {
      for (Field field in initializedFields.difference(fields)) {
        if (field.initializer == null) {
          FieldInitializer initializer =
              new FieldInitializer(field, new NullLiteral())
                ..isSynthetic = true;
          initializer.parent = constructor;
          constructor.initializers.insert(0, initializer);
          if (field.isFinal) {
            builder.library.addProblem(
                templateFinalFieldNotInitializedByConstructor
                    .withArguments(field.name.name),
                constructor.fileOffset,
                constructor.name.name.length,
                constructor.fileUri,
                context: [
                  templateMissingImplementationCause
                      .withArguments(field.name.name)
                      .withLocation(field.fileUri, field.fileOffset,
                          field.name.name.length)
                ]);
          } else if (field.type is! InvalidType &&
              field.type.isPotentiallyNonNullable) {
            SourceLibraryBuilder library = builder.library;
            if (library.isNonNullableByDefault &&
                library.loader.performNnbdChecks) {
              if (library.loader.nnbdStrongMode) {
                library.addProblem(
                    templateFieldNonNullableNotInitializedByConstructorError
                        .withArguments(field.name.name, field.type,
                            library.isNonNullableByDefault),
                    field.fileOffset,
                    field.name.name.length,
                    library.fileUri);
              } else {
                library.addProblem(
                    templateFieldNonNullableNotInitializedByConstructorWarning
                        .withArguments(field.name.name, field.type,
                            library.isNonNullableByDefault),
                    field.fileOffset,
                    field.name.name.length,
                    library.fileUri);
              }
            }
          }
        }
      }
    });
  }

  /// Run all transformations that are needed when building a bundle of
  /// libraries for the first time.
  void runBuildTransformations() {
    backendTarget.performPreConstantEvaluationTransformations(
        component,
        loader.coreTypes,
        loader.libraries,
        new KernelDiagnosticReporter(loader),
        logger: (String msg) => ticker.logMs(msg));

    TypeEnvironment environment =
        new TypeEnvironment(loader.coreTypes, loader.hierarchy);
    constants.EvaluationMode evaluationMode;
    if (enableNonNullable) {
      if (loader.nnbdStrongMode) {
        evaluationMode = constants.EvaluationMode.strong;
      } else {
        evaluationMode = constants.EvaluationMode.weak;
      }
    } else {
      evaluationMode = constants.EvaluationMode.legacy;
    }

    constants.transformLibraries(
        loader.libraries,
        backendTarget.constantsBackend(loader.coreTypes),
        environmentDefines,
        environment,
        new KernelConstantErrorReporter(loader),
        evaluationMode,
        desugarSets: !backendTarget.supportsSetLiterals,
        enableTripleShift: enableTripleShift,
        errorOnUnevaluatedConstant: errorOnUnevaluatedConstant);
    ticker.logMs("Evaluated constants");

    backendTarget.performModularTransformationsOnLibraries(
        component,
        loader.coreTypes,
        loader.hierarchy,
        loader.libraries,
        environmentDefines,
        new KernelDiagnosticReporter(loader),
        loader.referenceFromIndex,
        logger: (String msg) => ticker.logMs(msg),
        changedStructureNotifier: changedStructureNotifier);
  }

  ChangedStructureNotifier get changedStructureNotifier => null;

  void runProcedureTransformations(Procedure procedure) {
    backendTarget.performTransformationsOnProcedure(
        loader.coreTypes, loader.hierarchy, procedure,
        logger: (String msg) => ticker.logMs(msg));
  }

  void verify() {
    // TODO(ahe): How to handle errors.
    verifyComponent(component);
    ClassHierarchy hierarchy =
        new ClassHierarchy(component, new CoreTypes(component),
            onAmbiguousSupertypes: (Class cls, Supertype a, Supertype b) {
      // An error has already been reported.
    });
    verifyGetStaticType(
        new TypeEnvironment(loader.coreTypes, hierarchy), component);
    ticker.logMs("Verified component");
  }

  /// Return `true` if the given [library] was built by this [KernelTarget]
  /// from sources, and not loaded from a [DillTarget].
  bool isSourceLibrary(Library library) {
    return loader.libraries.contains(library);
  }

  @override
  void readPatchFiles(SourceLibraryBuilder library) {
    assert(library.importUri.scheme == "dart");
    List<Uri> patches = uriTranslator.getDartPatches(library.importUri.path);
    if (patches != null) {
      SourceLibraryBuilder first;
      for (Uri patch in patches) {
        if (first == null) {
          first = library.loader.read(patch, -1,
              fileUri: patch, origin: library, accessor: library);
        } else {
          // If there's more than one patch file, it's interpreted as a part of
          // the patch library.
          SourceLibraryBuilder part = library.loader.read(patch, -1,
              origin: library, fileUri: patch, accessor: library);
          first.parts.add(part);
          first.partOffsets.add(-1);
          part.partOfUri = first.importUri;
        }
      }
    }
  }

  void releaseAncillaryResources() {
    component = null;
  }
}

/// Looks for a constructor call that matches `super()` from a constructor in
/// [cls]. Such a constructor may have optional arguments, but no required
/// arguments.
Constructor defaultSuperConstructor(Class cls) {
  Class superclass = cls.superclass;
  if (superclass != null) {
    for (Constructor constructor in superclass.constructors) {
      if (constructor.name.name.isEmpty) {
        return constructor.function.requiredParameterCount == 0
            ? constructor
            : null;
      }
    }
  }
  return null;
}

class KernelDiagnosticReporter
    extends DiagnosticReporter<Message, LocatedMessage> {
  final Loader loader;

  KernelDiagnosticReporter(this.loader);

  void report(Message message, int charOffset, int length, Uri fileUri,
      {List<LocatedMessage> context}) {
    loader.addProblem(message, charOffset, noLength, fileUri, context: context);
  }
}

/// Data for updating cloned parameters of parameters with inferred parameter
/// types.
///
/// The type of [source] is not declared so the type of [target] needs to be
/// updated when the type of [source] has been inferred.
class DelayedParameterType {
  final VariableDeclaration source;
  final VariableDeclaration target;
  final Map<TypeParameter, DartType> substitutionMap;

  DelayedParameterType(this.source, this.target, this.substitutionMap);

  void updateType() {
    assert(source.type != null, "No type computed for $source.");
    target.type = substitute(source.type, substitutionMap);
  }
}
