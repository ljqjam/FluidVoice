//
//  RecordingView.swift
//  fluid
//
//  Recording controls and configuration view
//

import AVFoundation
import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var appServices: AppServices
    private var asr: ASRService { self.appServices.asr }
    @Environment(\.theme) private var theme
    @Binding var appear: Bool

    let stopAndProcessTranscription: () async -> Void
    let startRecording: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                // Hero Header Card
                ThemedCard(style: .standard) {
                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("语音听写")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                Text("AI 驱动的语音识别")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }

                        // Status and Recording Control
                        VStack(spacing: 10) {
                            // Status indicator
                            HStack {
                                Circle()
                                    .fill(self.asr.isRunning ? .red : self.asr.isAsrReady ? Color.fluidGreen : .secondary)
                                    .frame(width: 8, height: 8)

                                Text(self.asr.isRunning ? "录音中..." : self.asr.isAsrReady ? "已就绪" : "模型未就绪")
                                    .font(.subheadline)
                                    .foregroundStyle(self.asr.isRunning ? .red : self.asr.isAsrReady ? Color.fluidGreen : .secondary)
                            }

                            // Recording Control (Single Toggle Button)
                            Button(action: {
                                if self.asr.isRunning {
                                    Task {
                                        await self.stopAndProcessTranscription()
                                    }
                                } else {
                                    self.startRecording()
                                }
                            }) {
                                HStack {
                                    Image(systemName: self.asr.isRunning ? "stop.fill" : "mic.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text(self.asr.isRunning ? "停止录音" : "开始录音")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .fluidButton(.primary, size: .large, isRecording: self.asr.isRunning)
                            .buttonHoverEffect()
                            .scaleEffect(self.asr.isRunning ? 1.05 : 1.0)
                            .animation(.spring(response: 0.3), value: self.asr.isRunning)
                            .disabled(!self.asr.isAsrReady && !self.asr.isRunning)
                        }
                    }
                    .padding(14)
                }
                .modifier(CardAppearAnimation(delay: 0.1, appear: self.$appear))
            }
            .padding(14)
        }
    }
}
