// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.camerax;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;

import androidx.camera.video.Recording;
import org.junit.Test;

public class RecordingTest {
  @Test
  public void close_removesRecordingFromActiveRecordings() {
    final TestProxyApiRegistrar registrar = new TestProxyApiRegistrar();
    final PigeonApiRecording api = registrar.getPigeonApiRecording();
    final Recording instance = mock(Recording.class);
    registrar.addActiveRecording(instance);

    api.close(instance);

    // Already closed by Dart: engine detach finds nothing left to close.
    org.junit.Assert.assertEquals(0, registrar.closeActiveRecordings());
    verify(instance, org.mockito.Mockito.times(1)).close();
  }

  @Test
  public void closeActiveRecordings_closesOpenRecordingsOnce() {
    final TestProxyApiRegistrar registrar = new TestProxyApiRegistrar();
    final Recording first = mock(Recording.class);
    final Recording second = mock(Recording.class);
    registrar.addActiveRecording(first);
    registrar.addActiveRecording(second);

    org.junit.Assert.assertEquals(2, registrar.closeActiveRecordings());
    org.junit.Assert.assertEquals(0, registrar.closeActiveRecordings());
    verify(first, org.mockito.Mockito.times(1)).close();
    verify(second, org.mockito.Mockito.times(1)).close();
  }

  @Test
  public void close_callsCloseOnInstance() {
    final PigeonApiRecording api = new TestProxyApiRegistrar().getPigeonApiRecording();

    final Recording instance = mock(Recording.class);
    api.close(instance);

    verify(instance).close();
  }

  @Test
  public void pause_callsPauseOnInstance() {
    final PigeonApiRecording api = new TestProxyApiRegistrar().getPigeonApiRecording();

    final Recording instance = mock(Recording.class);
    api.pause(instance);

    verify(instance).pause();
  }

  @Test
  public void resume_callsResumeOnInstance() {
    final PigeonApiRecording api = new TestProxyApiRegistrar().getPigeonApiRecording();

    final Recording instance = mock(Recording.class);
    api.resume(instance);

    verify(instance).resume();
  }

  @Test
  public void stop_callsStopOnInstance() {
    final PigeonApiRecording api = new TestProxyApiRegistrar().getPigeonApiRecording();

    final Recording instance = mock(Recording.class);
    api.stop(instance);

    verify(instance).stop();
  }
}
