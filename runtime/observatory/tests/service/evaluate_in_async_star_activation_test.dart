// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:developer';
import 'package:observatory/service_io.dart';
import 'package:unittest/unittest.dart';
import 'service_test_common.dart';
import 'test_helper.dart';

generator() async* {
  var x = 3;
  var y = 4;
  debugger();
  yield y;
  var z = x + y;
  debugger();
  yield z;
}

testFunction() async {
  await for (var ignored in generator());
}

var tests = [

hasStoppedAtBreakpoint,

(Isolate isolate) async {
  // Make sure we are in the right place.
  var stack = await isolate.getStack();
  var topFrame = 0;
  expect(stack.type, equals('Stack'));
  expect(await stack['frames'][topFrame].location.getLine(), 16);

  var result = await isolate.evalFrame(topFrame, "x");
  print(result);
  expect(result.valueAsString, equals("3"));
},

resumeIsolate,

hasStoppedAtBreakpoint,

(Isolate isolate) async {
  // Make sure we are in the right place.
  var stack = await isolate.getStack();
  var topFrame = 0;
  expect(stack.type, equals('Stack'));
  expect(await stack['frames'][topFrame].location.getLine(), 19);

  var result = await isolate.evalFrame(topFrame, "z");
  print(result);
  expect(result.valueAsString, equals("7"));
},

resumeIsolate,

];

main(args) => runIsolateTests(args, tests, testeeConcurrent: testFunction);
