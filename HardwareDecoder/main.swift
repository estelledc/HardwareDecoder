//
//  main.swift
//  HardwareDecoder
//
//  Created by TTHD on 2025/3/14.
//
import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - 全局变量
var decompressionSession: VTDecompressionSession?
var formatDescription: CMVideoFormatDescription?
var spsData: Data?
var ppsData: Data?

// MARK: - 常量定义
let kWidth = 1920
let kHeight = 1080
let kNaluHeaderLength = 4
let kVTDecodeQualityOfServiceTier_Max = 0
let kVTAvoidAsynchronousDecompressionKey = "VTAvoidAsynchronousDecompression"
let kVTDecodeOptionThrottleDecodingKey = "ThrottleDecoding"

// MARK: - 辅助函数
func printNALUData(_ data: Data, type: String) {
    print("\(type) 数据 (\(data.count) 字节):")
    let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
    print(hexString)
}

func removeStartCode(from data: Data) -> Data {
    if data.count >= 4 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
        return data.subdata(in: 4..<data.count)
    } else if data.count >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
        return data.subdata(in: 3..<data.count)
    }
    return data
}

func hasStartCode(_ data: Data) -> Bool {
    if data.count >= 4 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
        return true
    }
    if data.count >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
        return true
    }
    return false
}

func addStartCodeToNALU(_ data: Data) -> Data {
    let startCode = Data([0x00, 0x00, 0x00, 0x01])
    var nalData = data
    
    if !nalData.isEmpty {
        let nalHeader = nalData[0]
        nalData[0] = nalHeader & 0x7F  // 保留nal_ref_idc和nal_unit_type
    }
    
    return startCode + nalData
}

func fixNalHeader(_ data: inout Data) {
    if !data.isEmpty {
        let nalHeader = data[0]
        let forbidden_bit = (nalHeader & 0x80) >> 7
        
        if forbidden_bit != 0 {
            print("修正NAL头部的forbidden_bit")
            data[0] = nalHeader & 0x7F
        }
    }
}

// MARK: - 视频格式描述创建
func createVideoFormatDescription(sps: Data, pps: Data) -> Bool {
    printNALUData(sps, type: "SPS")
    printNALUData(pps, type: "PPS")
    
    let cleanSPS = removeStartCode(from: sps)
    let cleanPPS = removeStartCode(from: pps)
    
    if cleanSPS.isEmpty || cleanPPS.isEmpty {
        print("错误: SPS或PPS数据为空")
        return false
    }
    
    if cleanSPS.count < 4 {
        print("错误: SPS数据太短")
        return false
    }
    
    var parameterSetPointers: [UnsafePointer<UInt8>?] = [nil, nil]
    var parameterSetSizes: [Int] = [cleanSPS.count, cleanPPS.count]

    return cleanPPS.withUnsafeBytes { ppsBytes in
        guard let ppsBaseAddress = ppsBytes.baseAddress else { return false }
        parameterSetPointers[1] = ppsBaseAddress.assumingMemoryBound(to: UInt8.self)
        
        return cleanSPS.withUnsafeBytes { spsBytes in
            guard let spsBaseAddress = spsBytes.baseAddress else { return false }
            parameterSetPointers[0] = spsBaseAddress.assumingMemoryBound(to: UInt8.self)
            
            return parameterSetPointers.withUnsafeBufferPointer { pointers in
                let status = pointers.baseAddress!.withMemoryRebound(to: UnsafePointer<UInt8>.self, capacity: 2) { reboundPointers in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: reboundPointers,
                        parameterSetSizes: parameterSetSizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                }
                
                if status != noErr {
                    print("无法创建视频格式描述，错误码: \(status)")
                    print("SPS 头四字节: \(Array(cleanSPS.prefix(4)).map { String(format: "%02X", $0) }.joined(separator: " "))")
                    print("PPS 头四字节: \(Array(cleanPPS.prefix(min(4, cleanPPS.count))).map { String(format: "%02X", $0) }.joined(separator: " "))")
                }
                
                return status == noErr
            }
        }
    }
}

// MARK: - 解码会话创建
func createDecompressionSession() -> Bool {
    guard let formatDescription = formatDescription else {
        print("格式描述不存在")
        return false
    }
    
    // 设置解码参数 - 极致可靠性配置
    let decoderParameters = NSMutableDictionary()
    
    // 设置为同步解码模式，提高可靠性
    decoderParameters[kVTDecompressionPropertyKey_RealTime] = false
    decoderParameters[kVTAvoidAsynchronousDecompressionKey] = true
    decoderParameters[kVTDecompressionPropertyKey_ThreadCount] = 1
    
    // 显式设置为软件解码 
    decoderParameters[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false
    decoderParameters[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = false
    
    // 禁用优化，专注于可靠性
    decoderParameters[kVTDecompressionPropertyKey_MaximizePowerEfficiency] = false
    decoderParameters[kVTDecompressionPropertyKey_SuggestedQualityOfServiceTiers] = [
        kVTDecodeQualityOfServiceTier_Max
    ]
    decoderParameters[kVTDecodeOptionThrottleDecodingKey] = false
    
    // 设置像素缓冲区属性
    let destinationImageBufferAttributes = NSMutableDictionary()
    destinationImageBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    destinationImageBufferAttributes[kCVPixelBufferWidthKey] = kWidth
    destinationImageBufferAttributes[kCVPixelBufferHeightKey] = kHeight
    destinationImageBufferAttributes[kCVPixelBufferIOSurfacePropertiesKey] = [:]
    
    // 创建解码器回调
    var outputCallback = VTDecompressionOutputCallbackRecord(
        decompressionOutputCallback: decompressionOutputCallback,
        decompressionOutputRefCon: UnsafeMutableRawPointer(mutating: nil)
    )
    
    // 先释放已有的解码会话
    if let session = decompressionSession {
        VTDecompressionSessionInvalidate(session)
        decompressionSession = nil
    }
    
    // 创建解码会话
    let status = VTDecompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        formatDescription: formatDescription,
        decoderSpecification: decoderParameters,
        imageBufferAttributes: destinationImageBufferAttributes,
        outputCallback: &outputCallback,
        decompressionSessionOut: &decompressionSession
    )
    
    if status != noErr {
        print("无法创建解码会话，错误码: \(status)")
        
        // 尝试纯软件解码作为回退选项
        print("尝试创建纯软件解码器...")
        let softwareOnlyParams = NSMutableDictionary()
        softwareOnlyParams[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false
        softwareOnlyParams[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = false
        
        let retryStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: softwareOnlyParams,
            imageBufferAttributes: destinationImageBufferAttributes,
            outputCallback: &outputCallback,
            decompressionSessionOut: &decompressionSession
        )
        
        if retryStatus != noErr {
            print("纯软件解码器创建也失败，错误码: \(retryStatus)")
            return false
        } else {
            print("成功创建纯软件解码会话")
        }
    } else {
        print("成功创建解码会话")
        // 设置解码会话属性
        VTSessionSetProperty(decompressionSession!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanFalse)
    }
    
    return true
}

// MARK: - 解码回调
func decompressionOutputCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    duration: CMTime
) {
    if status != noErr {
        print("解码错误: \(status)")
        return
    }
    
    guard let imageBuffer = imageBuffer else {
        print("未获取到解码后的图像")
        return
    }
    
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    print("成功解码帧，分辨率: \(width)x\(height), 时间戳: \(CMTimeGetSeconds(presentationTimeStamp))")
    
    // 保存解码后的帧为图像文件
    saveFrame(imageBuffer: imageBuffer, frameIndex: presentationTimeStamp.value)
}

// MARK: - 帧保存
func saveFrame(imageBuffer: CVImageBuffer, frameIndex: Int64) {
    let ciImage = CIImage(cvImageBuffer: imageBuffer)
    let context = CIContext()
    
    if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
        let frameDir = NSHomeDirectory() + "/Desktop/decoded_frames"
        let framePath = "\(frameDir)/frame_\(frameIndex).png"
        
        // 确保目录存在
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: frameDir) {
            try? fileManager.createDirectory(atPath: frameDir, withIntermediateDirectories: true, attributes: nil)
        }
        
        // 使用CGImage创建PNG
        if let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: framePath) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, nil)
            if CGImageDestinationFinalize(destination) {
                print("保存帧到 \(framePath)")
            } else {
                print("无法保存帧")
            }
        } else {
            print("无法创建图像目标")
        }
    } else {
        print("无法创建CGImage")
    }
}

// MARK: - NAL单元解码
func decodeH264Nalu(data: Data, timestamp: CMTime) {
    guard let session = decompressionSession else {
        print("解码会话不存在")
        return
    }
    
    // 深拷贝数据以避免可能的内存问题
    var nalData = data
    
    // 1. 检查并修复NAL头部
    if !nalData.isEmpty {
        let nalHeader = nalData[0]
        let forbidden_bit = (nalHeader & 0x80) >> 7
        let nal_ref_idc = (nalHeader & 0x60) >> 5
        let nal_unit_type = nalHeader & 0x1F
        
        print("NAL头详情: forbidden_bit=\(forbidden_bit), nal_ref_idc=\(nal_ref_idc), nal_unit_type=\(nal_unit_type)")
        
        // 修复NAL头
        fixNalHeader(&nalData)
    } else {
        print("警告: NAL单元数据为空")
        return
    }
    
    // 2. 处理起始码
    let hasStartCodeAlready = hasStartCode(nalData)
    if !hasStartCodeAlready {
        print("添加起始码")
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        nalData = startCode + nalData
    }
    
    // 3. 获取NAL类型
    let nalHeaderIndex = hasStartCodeAlready ? 
                        (nalData[3] == 0x01 ? 4 : 3) : 
                        0
    
    let nalType: UInt8
    if nalHeaderIndex < nalData.count {
        nalType = nalData[nalHeaderIndex] & 0x1F
    } else {
        print("错误: 无法确定NAL类型")
        return
    }
    
    // 4. 创建块缓冲区
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: nalData.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: nalData.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    
    if status != kCMBlockBufferNoErr {
        print("无法创建块缓冲区，错误码: \(status)")
        return
    }
    
    // 5. 填充数据到块缓冲区
    status = CMBlockBufferReplaceDataBytes(
        with: [UInt8](nalData),
        blockBuffer: blockBuffer!,
        offsetIntoDestination: 0,
        dataLength: nalData.count
    )
    
    if status != kCMBlockBufferNoErr {
        print("无法填充块缓冲区，错误码: \(status)")
        return
    }
    
    // 6. 创建时间信息
    var timingInfo = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: timestamp,
        decodeTimeStamp: CMTime.invalid
    )
    
    // 7. 创建样本缓冲区
    var sampleBuffer: CMSampleBuffer?
    let sampleSizeArray = [nalData.count]
    
    status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: 1,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timingInfo,
        sampleSizeEntryCount: 1,
        sampleSizeArray: sampleSizeArray,
        sampleBufferOut: &sampleBuffer
    )
    
    if status != noErr || sampleBuffer == nil {
        print("无法创建采样缓冲区，错误码: \(status)")
        return
    }
    
    // 8. 设置关键帧标志
    if nalType == 5 { // IDR帧
        let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer!, createIfNecessary: true)!
        let attachments = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_IsDependedOnByOthers).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        CFDictionarySetValue(attachments, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanFalse).toOpaque())
    }
    
    // 9. 执行解码
    print("解码NAL类型: \(nalType), 长度: \(nalData.count)字节")
    
    // 使用同步解码模式尝试解码
    let decodeFlags = VTDecodeFrameFlags(rawValue: 0) // 同步解码
    var infoFlags = VTDecodeInfoFlags()
    
    let decodeStatus = VTDecompressionSessionDecodeFrame(
        session,
        sampleBuffer: sampleBuffer!,
        flags: decodeFlags,
        frameRefcon: nil,
        infoFlagsOut: &infoFlags
    )
    
    // 10. 处理解码结果
    if decodeStatus != noErr {
        print("解码错误: \(decodeStatus)")
        
        // 对特定错误进行处理
        if decodeStatus == -12909 { // kVTVideoDecoderMalfunctionErr
            print("解码器故障，执行紧急恢复...")
            
            // 完全重置解码管道
            cleanUp()
            
            // 重建格式描述
            if let sps = spsData, let pps = ppsData {
                if !createVideoFormatDescription(sps: sps, pps: pps) {
                    print("重建格式描述失败")
                    return
                }
                
                // 尝试使用最小化配置创建新的解码会话
                let emergencyParams = NSMutableDictionary()
                emergencyParams[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = false
                
                var outputCallback = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: decompressionOutputCallback,
                    decompressionOutputRefCon: UnsafeMutableRawPointer(mutating: nil)
                )
                
                let imageBufferAttributes = NSMutableDictionary()
                imageBufferAttributes[kCVPixelBufferPixelFormatTypeKey] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                
                let emergencyStatus = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: formatDescription!,
                    decoderSpecification: emergencyParams,
                    imageBufferAttributes: imageBufferAttributes,
                    outputCallback: &outputCallback,
                    decompressionSessionOut: &decompressionSession
                )
                
                if emergencyStatus == noErr && decompressionSession != nil {
                    print("紧急恢复成功，使用最小化软件解码配置")
                    
                    // 小延迟后重试当前帧
                    usleep(5000)
                    if nalType == 5 || nalType == 1 {
                        decodeH264Nalu(data: data, timestamp: timestamp)
                    }
                } else {
                    print("紧急恢复失败，无法继续解码")
                }
            }
        }
    } else {
        print("解码请求成功提交")
    }
}

// MARK: - 资源清理
func cleanUp() {
    if let session = decompressionSession {
        VTDecompressionSessionInvalidate(session)
        decompressionSession = nil
    }
    formatDescription = nil
}

// MARK: - 文件处理
func readH264File(path: String) -> Data? {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        print("成功读取视频文件，大小: \(data.count) 字节")
        return data
    } catch {
        print("读取文件失败: \(error.localizedDescription)")
        return nil
    }
}

func parseH264Stream(data: Data) -> [(nalUnitData: Data, nalUnitType: UInt8)] {
    var nalUnits: [(Data, UInt8)] = []
    var currentIndex = 0
    
    while currentIndex < data.count - 3 {
        // 查找起始码
        var startCodeLength = 0
        if currentIndex + 3 < data.count && data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 && data[currentIndex + 2] == 0x01 {
            startCodeLength = 3
        } else if currentIndex + 4 < data.count && data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 && data[currentIndex + 2] == 0x00 && data[currentIndex + 3] == 0x01 {
            startCodeLength = 4
        }
        
        if startCodeLength > 0 {
            let nalStart = currentIndex + startCodeLength
            
            // 查找下一个起始码
            var nextStartCodeIndex = nalStart
            while nextStartCodeIndex < data.count - 2 {
                if (data[nextStartCodeIndex] == 0x00 && data[nextStartCodeIndex + 1] == 0x00 && 
                   (nextStartCodeIndex + 2 < data.count && data[nextStartCodeIndex + 2] == 0x01)) ||
                   (nextStartCodeIndex + 3 < data.count && data[nextStartCodeIndex] == 0x00 && 
                   data[nextStartCodeIndex + 1] == 0x00 && data[nextStartCodeIndex + 2] == 0x00 && 
                   data[nextStartCodeIndex + 3] == 0x01) {
                    break
                }
                nextStartCodeIndex += 1
            }
            
            if nalStart < nextStartCodeIndex && nalStart < data.count {
                let nalData = data.subdata(in: nalStart..<nextStartCodeIndex)
                if !nalData.isEmpty {
                    let nalType = nalData[0] & 0x1F
                    nalUnits.append((nalData, nalType))
                }
            }
            
            currentIndex = nextStartCodeIndex
        } else {
            currentIndex += 1
        }
    }
    
    return nalUnits
}

func extractSPSandPPS(from nalUnits: [(Data, UInt8)]) -> (sps: Data?, pps: Data?) {
    var spsData: Data? = nil
    var ppsData: Data? = nil
    
    for (data, type) in nalUnits {
        if type == 7 {  // SPS
            spsData = data
            print("找到SPS，长度: \(data.count) 字节")
            
            // 验证SPS数据格式
            if data.count > 4 {
                let profileIdc = data[1]
                let levelIdc = data[3]
                print("SPS: Profile IDC = \(profileIdc), Level IDC = \(levelIdc)")
            }
        } else if type == 8 {  // PPS
            ppsData = data
            print("找到PPS，长度: \(data.count) 字节")
        }
        
        // 如果已经找到SPS和PPS，可以提前退出
        if spsData != nil && ppsData != nil {
            break
        }
    }
    return (spsData, ppsData)
}

// MARK: - 主函数
func main() {
    // 检查硬件解码支持
    let isHardwareSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    print("硬件H.264解码支持: \(isHardwareSupported)")
    
    // 尝试多个可能的文件路径
    let possiblePaths = [
        "~/Desktop/forshare/HardwareDecoder/HardwareDecoder/1.h264",
        "~/Desktop/forshare/HardwareDecoder/HardwareDecoder/video.h264",
        "~/Desktop/1.h264",
        "~/Desktop/video.h264"
    ]
    
    var videoData: Data? = nil
    var usedPath = ""
    
    for path in possiblePaths {
        let fullPath = NSString(string: path).expandingTildeInPath
        if FileManager.default.fileExists(atPath: fullPath) {
            print("找到视频文件: \(fullPath)")
            videoData = readH264File(path: fullPath)
            usedPath = fullPath
            break
        }
    }
    
    if videoData == nil {
        print("在所有可能的位置都找不到视频文件")
        print("请将H.264文件放在以下位置之一:")
        for path in possiblePaths {
            print("- \(NSString(string: path).expandingTildeInPath)")
        }
        return
    }
    
    print("使用视频文件: \(usedPath)")
    
    // 解析NAL单元
    let nalUnits = parseH264Stream(data: videoData!)
    print("共解析出\(nalUnits.count)个NAL单元")
    
    if nalUnits.isEmpty {
        print("没有找到有效的NAL单元")
        return
    }
    
    // 提取SPS和PPS
    let (extractedSps, extractedPps) = extractSPSandPPS(from: nalUnits)
    
    guard let sps = extractedSps, let pps = extractedPps else {
        print("无法找到SPS或PPS")
        return
    }
    
    // 保存到全局变量
    spsData = sps
    ppsData = pps
    
    // 创建视频格式描述
    if !createVideoFormatDescription(sps: sps, pps: pps) {
        print("无法创建视频格式描述")
        return
    }
    
    // 创建解码会话
    if !createDecompressionSession() {
        print("无法创建解码会话")
        return
    }
    
    print("解码器初始化成功，开始解码视频帧...")
    
    // 使用局部帧计数器
    var frameIndex: Int64 = 0
    
    // 解码帧
    for (idx, (nalData, nalType)) in nalUnits.enumerated() {
        // 只解码视频帧
        if nalType == 1 || nalType == 5 {
            print("\n开始解码第\(idx + 1)个NAL单元 (#\(frameIndex)) --------")
            print("类型: \(nalType == 5 ? "IDR帧" : "非IDR帧"), 大小: \(nalData.count)字节")
            
            // 为IDR帧重置解码器状态
            if nalType == 5 {
                print("IDR帧 - 重置解码器状态")
                cleanUp()
                
                if !createVideoFormatDescription(sps: spsData!, pps: ppsData!) {
                    print("无法重新创建视频格式描述")
                    continue
                }
                
                if !createDecompressionSession() {
                    print("无法重新创建解码会话")
                    continue
                }
                
                print("解码器已重置")
            }
            
            // 创建时间戳
            let timestamp = CMTime(value: frameIndex, timescale: 30)
            
            // 解码帧
            decodeH264Nalu(data: nalData, timestamp: timestamp)
            
            // 给解码器充足时间同步处理
            usleep(20000) // 20ms
            
            frameIndex += 1
        }
    }
    
    // 等待解码完成
    if let session = decompressionSession {
        print("等待所有帧完成处理...")
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        usleep(1000000) // 1秒
    }
    
    print("解码过程完成")
    print("处理了\(frameIndex)个视频帧")
    
    // 清理资源
    cleanUp()
}

// 运行程序
main()