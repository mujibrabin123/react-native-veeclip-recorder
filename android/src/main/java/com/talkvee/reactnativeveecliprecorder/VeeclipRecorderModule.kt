package com.talkvee.reactnativeveecliprecorder

import com.facebook.react.bridge.ReactApplicationContext

class VeeclipRecorderModule(reactContext: ReactApplicationContext) :
  NativeVeeclipRecorderSpec(reactContext) {

  override fun multiply(a: Double, b: Double): Double {
    return a * b
  }

  companion object {
    const val NAME = NativeVeeclipRecorderSpec.NAME
  }
}
