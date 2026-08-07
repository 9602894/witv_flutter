package com.befovy.fijkplayer;

import android.content.Context;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import io.flutter.view.TextureRegistry;

/**
 * FijkPlugin
 * 
 * 修复 Flutter 3.44+ 兼容性：移除了废弃的 PluginRegistry.Registrar API
 * 仅保留 FlutterPlugin 接口实现
 */
public class FijkPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {

    private static final String TAG = "FijkPlugin";

    private MethodChannel mMethodChannel;
    private EventChannel mEventChannel;
    private EventChannel.EventSink mEventSink;

    private FlutterPluginBinding mBinding;
    private TextureRegistry mTextureRegistry;
    private BinaryMessenger mMessenger;

    static FijkPlugin instance() {
        return _instance;
    }

    private static FijkPlugin _instance;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        _instance = this;
        mBinding = binding;
        mTextureRegistry = binding.getTextureRegistry();
        mMessenger = binding.getBinaryMessenger();

        mMethodChannel = new MethodChannel(mMessenger, "befovy.com/fijk");
        mMethodChannel.setMethodCallHandler(this);

        mEventChannel = new EventChannel(mMessenger, "befovy.com/fijk/event");
        mEventChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                mEventSink = events;
            }

            @Override
            public void onCancel(Object arguments) {
                mEventSink = null;
            }
        });
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        mMethodChannel.setMethodCallHandler(null);
        mMethodChannel = null;
        mEventChannel.setStreamHandler(null);
        mEventChannel = null;
        mEventSink = null;
        mTextureRegistry = null;
        mMessenger = null;
        mBinding = null;
        _instance = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "init":
                result.success(null);
                break;
            case "createPlayer": {
                int pid = call.argument("pid");
                FijkPlayer player = new FijkPlayer();
                player.setup(pid, mMessenger, mTextureRegistry);
                result.success(null);
                break;
            }
            case "releasePlayer": {
                int pid = call.argument("pid");
                FijkPlayer player = FijkPlayer.getPlayer(pid);
                if (player != null) {
                    player.release();
                }
                result.success(null);
                break;
            }
            case "setLogLevel": {
                int level = call.argument("level");
                FijkPlayer.setLogLevel(level);
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
                break;
        }
    }

    void postEvent(Object event) {
        if (mEventSink != null) {
            new Handler(Looper.getMainLooper()).post(() -> {
                if (mEventSink != null) {
                    mEventSink.success(event);
                }
            });
        }
    }
}
