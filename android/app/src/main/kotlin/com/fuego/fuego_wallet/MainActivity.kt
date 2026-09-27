package com.fuego.fuego_wallet

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.fuego.fuego_wallet/native_lib_dir"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getNativeLibraryDir") {
                // applicationInfo.nativeLibraryDir is where Android extracts
                // jniLibs/*.so at install time with execute permission set —
                // the only way to run a bundled arbitrary executable
                // (fuego_walletd, shipped as libfuego_walletd.so) on
                // non-rooted Android.
                result.success(applicationInfo.nativeLibraryDir)
            } else {
                result.notImplemented()
            }
        }
    }
}
