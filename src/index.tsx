import { NativeModules, Platform } from 'react-native';

const LINKING_ERROR =
  `The package 'react-native-veeclip-recorder' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go; this package requires a development build\n';

const VeeclipRecorder = NativeModules.VeeclipRecorder
  ? NativeModules.VeeclipRecorder
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

/**
 * Checks if the current device supports native WebRTC recording.
 */
export async function isSupported(): Promise<boolean> {
  return await VeeclipRecorder.isSupported();
}

/**
 * Starts the dual-stream recording process.
 * @param localViewTag The findNodeHandle() result of the local RTCView.
 * @param remoteViewTag The findNodeHandle() result of the remote RTCView.
 * @param options Configuration including 'layout' ('vertical' | 'horizontal').
 */
export async function startRecording(
  localViewTag: number | null,
  remoteViewTag: number | null,
  options: { layout?: 'vertical' | 'horizontal' }
): Promise<void> {
  return await VeeclipRecorder.startRecording(localViewTag, remoteViewTag, options);
}

/**
 * Stops the recording and returns the final MP4 file metadata.
 * @returns An object containing the local file URI and mimeType.
 */
export async function stopRecording(): Promise<{ videoUri: string; mimeType: string }> {
  return await VeeclipRecorder.stopRecording();
}