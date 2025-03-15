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
import UniformTypeIdentifiers // 添加这行导入UTType

// 存储解码会话
var decompressionSession: VTDecompressionSession?
// 存储视频格式描述
var formatDescription: CMVideoFormatDescription?

// 用于创建视频格式描述的参数
let kWidth = 1920
let kHeight = 1080
let kNaluHeaderLength = 4

// 添加一个打印SPS/PPS数据的函数
func printNALUData(_ data: Data, type: String) {
    print("\(type) 数据 (\(data.count) 字节):")
    let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
    print(hexString)
}

// 移除起始码的函数
func removeStartCode(from data: Data) -> Data {
    if data.count >= 4 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
        return data.subdata(in: 4..<data.count)
    } else if data.count >= 3 && data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
        return data.subdata(in: 3..<data.count)
    }
    return data
}

// 创建H.264格式描述
func createVideoFormatDescription(sps: Data, pps: Data) -> Bool {
    // 打印SPS和PPS数据
    printNALUData(sps, type: "SPS")
    printNALUData(pps, type: "PPS")
    
    // 确保SPS和PPS不包含起始码
    let cleanSPS = removeStartCode(from: sps)
    let cleanPPS = removeStartCode(from: pps)
    
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
                }
                
                return status == noErr
            }
        }
    }
}

// 解码回调函数
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
    
    // 处理解码后的帧
    let width = CVPixelBufferGetWidth(imageBuffer)
    let height = CVPixelBufferGetHeight(imageBuffer)
    print("成功解码帧，分辨率: \(width)x\(height), 时间戳: \(CMTimeGetSeconds(presentationTimeStamp))")
    
    // 可选：保存解码后的帧为图像文件
    saveFrame(imageBuffer: imageBuffer, frameIndex: presentationTimeStamp.value)
}

// 添加保存帧函数
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

// 创建解码会话
func createDecompressionSession() -> Bool {
    guard let formatDescription = formatDescription else {
        print("格式描述不存在")
        return false
    }
    
    // 设置解码参数
    let decoderParameters = NSMutableDictionary()
    // 启用异步解码模式
    decoderParameters[kVTDecompressionPropertyKey_RealTime] = false
    decoderParameters[kVTDecompressionPropertyKey_ThreadCount] = 1
    // 允许硬解码失败时自动回退到软解码
    decoderParameters[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true
    decoderParameters[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = false
    
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
    }
    
    return status == noErr
}

// 创建一个添加起始码的函数
func addStartCodeToNALU(_ data: Data) -> Data {
    let startCode = Data([0x00, 0x00, 0x00, 0x01])
    return startCode + data
}

// 解码H.264 NAL单元
func decodeH264Nalu(data: Data, timestamp: CMTime) {
    guard let session = decompressionSession else {
        print("解码会话不存在")
        return
    }
    
    // 添加起始码到NAL单元数据
    let dataWithStartCode = addStartCodeToNALU(data)
    
    // 创建包含编码数据的块缓冲区
    var blockBuffer: CMBlockBuffer?
    let status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: dataWithStartCode.count,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: dataWithStartCode.count,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    
    if status != kCMBlockBufferNoErr {
        print("无法创建块缓冲区，错误码: \(status)")
        return
    }
    
    // 将数据填充到块缓冲区
    let dataBytes = [UInt8](dataWithStartCode)
    let replaceStatus = CMBlockBufferReplaceDataBytes(
        with: dataBytes,
        blockBuffer: blockBuffer!,
        offsetIntoDestination: 0,
        dataLength: dataWithStartCode.count
    )
    
    if replaceStatus != kCMBlockBufferNoErr {
        print("无法填充块缓冲区，错误码: \(replaceStatus)")
        return
    }
    
    // 创建采样缓冲区
    var sampleBuffer: CMSampleBuffer?
    let sampleSizeArray = [dataWithStartCode.count]
    
    // 创建时间信息
    var timingInfo = CMSampleTimingInfo(
        duration: CMTime.invalid,
        presentationTimeStamp: timestamp,
        decodeTimeStamp: CMTime.invalid
    )
    
    let createStatus = CMSampleBufferCreate(
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
    
    if createStatus != noErr || sampleBuffer == nil {
        print("无法创建采样缓冲区，错误码: \(createStatus)")
        return
    }
    
    // 解码帧
    let decodeFlags = VTDecodeFrameFlags._1xRealTimePlayback
    var infoFlags = VTDecodeInfoFlags()
    let decodeStatus = VTDecompressionSessionDecodeFrame(
        session,
        sampleBuffer: sampleBuffer!,
        flags: decodeFlags,
        frameRefcon: nil,
        infoFlagsOut: &infoFlags
    )
    
    if decodeStatus != noErr {
        print("解码帧失败，错误码: \(decodeStatus)")
    }
}

// 清理资源
func cleanUp() {
    if let session = decompressionSession {
        VTDecompressionSessionInvalidate(session)
        decompressionSession = nil
    }
    formatDescription = nil
}

// 读取H.264文件
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

// 解析H.264文件，提取NAL单元
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

// 从H.264流中提取SPS和PPS
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

// 主函数示例
func main() {
    // 检查硬件解码支持
    let isHardwareSupported = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    print("硬件H.264解码支持: \(isHardwareSupported)")

    // 从文件加载H.264视频
    let videoPath = NSString(string: "~/Desktop/forshare/HardwareDecoder/HardwareDecoder/video.h264").expandingTildeInPath
    
    // 检查文件是否存在
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: videoPath) {
        print("警告: 视频文件不存在于路径: \(videoPath)")
        print("请确保视频文件放在正确的位置")
        return
    }
    
    print("尝试从路径加载视频: \(videoPath)")
    guard let videoData = readH264File(path: videoPath) else {
        print("无法读取视频文件")
        return
    }
    
    // 解析H.264流，提取NAL单元
    let nalUnits = parseH264Stream(data: videoData)
    print("共解析出\(nalUnits.count)个NAL单元")
    
    // 提取SPS和PPS
    let (spsData, ppsData) = extractSPSandPPS(from: nalUnits)
    
    guard let sps = spsData, let pps = ppsData else {
        print("无法找到SPS或PPS")
        return
    }
    
    // 使用真实的SPS和PPS创建视频格式描述
    if !createVideoFormatDescription(sps: sps, pps: pps) {
        print("无法创建视频格式描述")
        return
    }
    
    if !createDecompressionSession() {
        print("无法创建解码会话")
        cleanUp()
        return
    }
    
    print("解码器初始化成功，开始解码视频帧...")
    
    // 创建一个时间戳计数器
    var frameIndex: Int64 = 0
    
    // 解码所有帧NAL单元（跳过SPS和PPS）
    for (nalData, nalType) in nalUnits {
        // 只解码IDR帧(5)和非IDR帧(1)等实际视频帧
        if nalType == 1 || nalType == 5 {  // 1=非IDR帧, 5=IDR帧
            print("解码NAL单元类型: \(nalType)，长度: \(nalData.count) 字节")
            
            // 确保每个I帧（IDR帧）前都重新发送SPS和PPS
            if nalType == 5 && spsData != nil && ppsData != nil {
                // 在每个I帧前重新发送SPS和PPS，有助于解决解码问题
                print("为IDR帧重新发送SPS和PPS")
                decodeH264Nalu(data: spsData!, timestamp: CMTime.invalid)
                decodeH264Nalu(data: ppsData!, timestamp: CMTime.invalid)
            }
            
            let timestamp = CMTime(value: frameIndex, timescale: 30)
            decodeH264Nalu(data: nalData, timestamp: timestamp)
            frameIndex += 1
        } else if nalType != 7 && nalType != 8 {  // 不是SPS和PPS的其他类型NAL单元
            let timestamp = CMTime(value: frameIndex, timescale: 30)
            decodeH264Nalu(data: nalData, timestamp: timestamp)
            frameIndex += 1
        }
    }
    
    // 等待解码完成
    if let session = decompressionSession {
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }
    
    print("解码完成，共处理\(frameIndex)帧")
    
    // 清理资源
    cleanUp()
}

// 运行程序
main()
