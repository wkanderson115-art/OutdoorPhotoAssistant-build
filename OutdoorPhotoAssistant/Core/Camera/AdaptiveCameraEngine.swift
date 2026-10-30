import AVFoundation
import Foundation

/// 设备自适应引擎：按内存/核心数/热状态/低电量选择档位，并把档位真正用起来
/// （控制 HDR、拍照质量优先级、是否请求最大照片尺寸）。
final class AdaptiveCameraEngine {
    enum Tier: String {
        case light = "轻量"
        case balanced = "均衡"
        case high = "高性能"
    }

    struct Profile {
        let tier: Tier
        let enableHDR: Bool
        let preferQualityCapture: Bool
        let allowMaxDimensions: Bool

        var summary: String {
            switch tier {
            case .light: return "低负载·硬件优先"
            case .balanced: return "均衡·画质优先"
            case .high: return "高性能·极致画质"
            }
        }
    }

    private(set) var profile = AdaptiveCameraEngine.makeProfile()

    static func makeProfile() -> Profile {
        let info = ProcessInfo.processInfo
        let memoryGB = Double(info.physicalMemory) / 1_073_741_824.0
        let cores = info.processorCount
        let thermal = info.thermalState
        let lowPower = info.isLowPowerModeEnabled

        if thermal == .serious || thermal == .critical || memoryGB < 3.0 || cores <= 4 || lowPower {
            return Profile(tier: .light,
                           enableHDR: false,
                           preferQualityCapture: true,
                           allowMaxDimensions: false)
        }
        if memoryGB >= 6.0 && cores >= 6 && thermal == .nominal {
            return Profile(tier: .high,
                           enableHDR: true,
                           preferQualityCapture: true,
                           allowMaxDimensions: true)
        }
        return Profile(tier: .balanced,
                       enableHDR: true,
                       preferQualityCapture: true,
                       allowMaxDimensions: true)
    }

    func refreshProfile() {
        profile = Self.makeProfile()
    }

    /// 只做"能让硬件自动算法参与"的配置，不用软件模拟 AE/AF/AWB。
    func configure(_ device: AVCaptureDevice) {
        refreshProfile()
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = profile.enableHDR
            }
        } catch {
            // 个别机型不支持其中某项时，保留其它已成功设置的能力。
        }
    }

    func prepare(_ settings: AVCapturePhotoSettings,
                 output: AVCapturePhotoOutput,
                 highQuality: Bool) {
        refreshProfile()
        settings.flashMode = .off
        settings.photoQualityPrioritization = profile.preferQualityCapture ? .quality : .balanced
        if output.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = true
        }
        if output.isContentAwareDistortionCorrectionEnabled {
            settings.isAutoContentAwareDistortionCorrectionEnabled = true
        }

        if highQuality {
            settings.maxPhotoDimensions = output.maxPhotoDimensions
        }

        // 关键：只有输出层真的打开了 depth / matte，才能往照片请求里加，
        // 否则 AVFoundation 会抛异常（这是上一版"按下快门即崩溃"的根因）。
        if output.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = true
            if output.isPortraitEffectsMatteDeliveryEnabled {
                settings.isPortraitEffectsMatteDeliveryEnabled = true
                settings.embedsPortraitEffectsMatteInPhoto = true
            }
        }
    }
}

// Portions adapted from NextLevel/NextLevel, Sources/NextLevel.swift.
// Copyright (c) 2016-present patrick piemonte, NextLevel.
// MIT license: ThirdParty/NextLevel/LICENSE (included in the source distribution).
// Upstream blob: fbf90185f15c26709d76e6c53816b68fd622b86e
// Adaptations: explicit device injection, success/error propagation, defer unlock,
// dynamic zoom limits and an optional ramp. Caller owns session queue serialization.
enum NextLevelDeviceControls {
    static let licenseText = """
The MIT License (MIT)

Copyright (c) 2016-present patrick piemonte (http://patrickpiemonte.com), NextLevel (http://nextlevel.engineering/)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

    /// Derived from NextLevel.expose(withTargetBias:force:completionHandler:).
    @discardableResult
    static func expose(_ device: AVCaptureDevice, targetBias: Float, force: Bool = false) throws -> Bool {
        guard !device.isAdjustingExposure || force else { return false }
        let newTargetBias = max(device.minExposureTargetBias, min(targetBias, device.maxExposureTargetBias))
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.setExposureTargetBias(newTargetBias, completionHandler: nil)
        return true
    }

    /// Derived from NextLevel.videoZoomFactor's setter.
    @discardableResult
    static func zoom(_ device: AVCaptureDevice, factor: CGFloat, animated: Bool) throws -> CGFloat {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        let minimum = device.minAvailableVideoZoomFactor
        let maximum = max(minimum, min(device.maxAvailableVideoZoomFactor,
                                         device.activeFormat.videoMaxZoomFactor))
        let target = max(minimum, min(factor, maximum))
        if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
        if animated {
            device.ramp(toVideoZoomFactor: target, withRate: Float(max(3, abs(target - device.videoZoomFactor) * 4)))
        } else {
            device.videoZoomFactor = target
        }
        return target
    }
}
