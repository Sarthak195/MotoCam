// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import android.Manifest;
import android.content.pm.PackageManager;
import androidx.annotation.NonNull;
import androidx.camera.video.ExperimentalPersistentRecording;
import androidx.camera.video.PendingRecording;
import androidx.camera.video.Recording;
import androidx.camera.video.VideoRecordEvent;
import androidx.core.content.ContextCompat;

/**
 * ProxyApi implementation for {@link PendingRecording}. This class may handle instantiating native
 * object instances that are attached to a Dart instance or handle method calls on the associated
 * native class or an instance of that class.
 */
class PendingRecordingProxyApi extends PigeonApiPendingRecording {
  PendingRecordingProxyApi(@NonNull ProxyApiRegistrar pigeonRegistrar) {
    super(pigeonRegistrar);
  }

  @NonNull
  @Override
  public ProxyApiRegistrar getPigeonRegistrar() {
    return (ProxyApiRegistrar) super.getPigeonRegistrar();
  }

  @ExperimentalPersistentRecording
  @NonNull
  @Override
  public PendingRecording asPersistentRecording(PendingRecording pigeonInstance) {
    return pigeonInstance.asPersistentRecording();
  }

  @NonNull
  @Override
  public PendingRecording withAudioEnabled(PendingRecording pigeonInstance, boolean initialMuted) {
    boolean hasPermission =
        ContextCompat.checkSelfPermission(
                getPigeonRegistrar().getContext(), Manifest.permission.RECORD_AUDIO)
            == PackageManager.PERMISSION_GRANTED;

    if (hasPermission) {
      return pigeonInstance.withAudioEnabled(initialMuted);
    }

    // By default, the recording will not contain audio.
    return pigeonInstance;
  }

  @NonNull
  @Override
  public Recording start(
      PendingRecording pigeonInstance, @NonNull VideoRecordEventListener listener) {
    // MotoCam patch: track the recording until it is closed, stopped or finalized, so the plugin
    // can stop it if the engine detaches first (ProxyApiRegistrar#closeActiveRecordings). Events
    // run on the main executor, after this method has returned and filled the holder.
    final Recording[] started = new Recording[1];
    final Recording recording =
        pigeonInstance.start(
            ContextCompat.getMainExecutor(getPigeonRegistrar().getContext()),
            event -> {
              if (event instanceof VideoRecordEvent.Finalize && started[0] != null) {
                getPigeonRegistrar().removeActiveRecording(started[0]);
              }
              listener.onEvent(event);
            });
    started[0] = recording;
    getPigeonRegistrar().addActiveRecording(recording);
    return recording;
  }
}
