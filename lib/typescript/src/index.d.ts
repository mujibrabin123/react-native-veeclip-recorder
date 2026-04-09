/**
 * Checks if the current device supports native WebRTC recording.
 */
export declare function isSupported(): Promise<boolean>;
/**
 * Starts the dual-stream recording process.
 * @param localViewTag The findNodeHandle() result of the local RTCView.
 * @param remoteViewTag The findNodeHandle() result of the remote RTCView.
 * @param options Configuration for the recording session.
 */
export declare function startRecording(localViewTag: number | null, remoteViewTag: number | null, options: {
    layout?: 'vertical' | 'horizontal';
    durationSec?: number;
    watermark?: boolean;
}): Promise<void>;
/**
 * Stops the recording and returns the final MP4 file metadata.
 * @returns An object containing the local file URI, mimeType, and optional thumbnail.
 */
export declare function stopRecording(): Promise<{
    videoUri: string;
    mimeType: string;
    thumbnailUri?: string;
}>;
//# sourceMappingURL=index.d.ts.map