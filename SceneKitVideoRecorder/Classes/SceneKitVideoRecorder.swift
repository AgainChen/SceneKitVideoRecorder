//
//  SceneKitVideoRecorder.swift
//
//  Created by Omer Karisman on 2017/08/29.
//
#if arch(i386) || arch(x86_64)
  import UIKit
  import SceneKit
  public class SceneKitVideoRecorder {
    public init?(scene: SCNView, options: Options = .default) throws {}
    public func startWriting() {}
    public func finishWriting(completionHandler: (@escaping (_ url: URL) -> Void)) {}
  }
  //Metal does not work in simulator :(
#else

  import UIKit
  import SceneKit
  import ARKit
  import AVFoundation
  import Metal
  import CoreImage

  public class SceneKitVideoRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var writer: AVAssetWriter!
    private var videoInput: AVAssetWriterInput!
    private var audioInput: AVAssetWriterInput!
    private var captureSession: AVCaptureSession!

    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor!
    private var options: Options
    private var currentDrawable: CAMetalDrawable?

    private let frameQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.frameQueue")
    private static let renderQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.renderQueue", attributes: .concurrent)
    private let bufferQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.bufferQueue", attributes: .concurrent)
    private let audioQueue = DispatchQueue(label: "com.svtek.SceneKitVideoRecorder.audioQueue")

    private static let renderSemaphore = DispatchSemaphore(value: 3)
    private static let frameRenderSemaphore = DispatchSemaphore(value: 1)
    private static let bufferAppendSemaphore = DispatchSemaphore(value: 1)

    private var displayLink: CADisplayLink? = nil
    private var initialTime: CFTimeInterval = 0.0
    private var currentTime: CFTimeInterval = 0.0

    private var sceneView: SCNView
    private var metalLayer: CAMetalLayer

    private var audioSettings: [String : Any]?

    private var isRecording: Bool = false
    private var videoFramesWritten: Bool = false

    public var updateFrameHandler: ((_ image: UIImage, _ time: CMTime) -> Void)? = nil
    private var finishedCompletionHandler: ((_ url: URL) -> Void)? = nil
    private let context:CIContext

    @available(iOS 11.0, *)
    public convenience init?(withARSCNView view: ARSCNView, options: Options = .default) throws {
      var options = options
      options.videoSize = CGSize(width: view.bounds.width * view.contentScaleFactor, height: view.bounds.height * view.contentScaleFactor)
      try self.init(scene: view, options: options)
    }

    public init?(scene: SCNView, options: Options = .default) throws {

      self.sceneView = scene

      self.context = CIContext.init(mtlDevice: MTLCreateSystemDefaultDevice()!)

      self.metalLayer = (sceneView.layer as? CAMetalLayer)!
      self.metalLayer.framebufferOnly = false

      self.options = options

      let currentDrawable = metalLayer.nextDrawable()

      self.options.videoSize = (currentDrawable?.layer.drawableSize)!

      self.isRecording = false
      self.videoFramesWritten = false

      //Handle mic permissions in a nice way.
      //AVAudioSession.sharedInstance().requestRecordPermission()

      super.init()

      self.setupAudio()
    }

    public func prepare() {
      prepare(with: self.options)
    }

    private func setupAudio () {
      
      let device: AVCaptureDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeAudio)
      if (device.isConnected) {
        //print("Connected Device: %@", device.localizedName);
      } else {
        //print("AVCaptureDevice Failed");
        return
      }

      let audioCaptureInput = try! AVCaptureDeviceInput.init(device: device)

      let audioCaptureOutput = AVCaptureAudioDataOutput.init()

      audioCaptureOutput.setSampleBufferDelegate(self, queue: audioQueue)

      captureSession = AVCaptureSession.init()

      captureSession.sessionPreset = AVCaptureSessionPresetMedium

      captureSession.addInput(audioCaptureInput)
      captureSession.addOutput(audioCaptureOutput)

      self.audioSettings = audioCaptureOutput.recommendedAudioSettingsForAssetWriter(withOutputFileType: AVFileTypeAppleM4V) as? [String : Any]

      self.audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: audioSettings )

      self.audioInput.expectsMediaDataInRealTime = true

      audioQueue.async { [weak self] in
        self?.captureSession.startRunning()
      }
    }

    private func prepare(with options: Options) {
      let currentDrawable = metalLayer.nextDrawable()

      self.options.videoSize = (currentDrawable?.layer.drawableSize)!

      self.writer = try! AVAssetWriter(outputURL: self.options.outputUrl,
                                       fileType: self.options.fileType)
      self.videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo,
                                           outputSettings: self.options.assetWriterVideoInputSettings)

      self.videoInput.mediaTimeScale = self.options.timeScale

      self.pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput,sourcePixelBufferAttributes: self.options.sourcePixelBufferAttributes)

      writer.add(videoInput)
      writer.add(audioInput)
    }

    public func cleanUp() {
      if options.deleteFileIfExists {
        FileController.delete(file: options.outputUrl)
      }
    }

    public func startWriting() {
      cleanUp()
      SceneKitVideoRecorder.renderQueue.async { [weak self] in
        SceneKitVideoRecorder.renderSemaphore.wait()

        self?.startDisplayLink()
        self?.startInputPipeline()
        self?.isRecording = self?.writer.status == AVAssetWriterStatus.writing
      }
    }

    public func finishWriting(completionHandler: (@escaping (_ url: URL) -> Void)) {
      let outputUrl = options.outputUrl
      videoInput.markAsFinished()
      audioInput.markAsFinished()
      self.stopDisplayLink()
      self.isRecording = false
      writer.finishWriting(completionHandler: { _ in
        completionHandler(outputUrl)
        self.prepare(with: self.options)
        SceneKitVideoRecorder.renderSemaphore.signal()
      })
    }

    private func startDisplayLink() {

      currentTime = 0.0
      initialTime = CFAbsoluteTimeGetCurrent()
      displayLink = CADisplayLink(target: self, selector: #selector(updateDisplayLink))
      displayLink?.preferredFramesPerSecond = options.fps
      displayLink?.add(to: .main, forMode: .commonModes)

    }

    @objc private func updateDisplayLink() {
      frameQueue.async { [weak self] in
        guard let input = self?.videoInput, input.isReadyForMoreMediaData else { return }
        self?.renderSnapshot()
      }
    }

    private func startInputPipeline() {
      let millisElapsed = NSDate().timeIntervalSince(audioCaptureStartedAt! as Date) * Double(options.timeScale)
      writer.startWriting()
      writer.startSession(atSourceTime: CMTimeAdd(firstAudioTimestamp!, CMTimeMake(Int64(millisElapsed), Int32(options.timeScale))))
      videoInput.requestMediaDataWhenReady(on: frameQueue, using: {})
    }

    private func renderSnapshot() {
      if !videoInput.isReadyForMoreMediaData { return }

      autoreleasepool {

        while (currentDrawable == nil) {
          currentDrawable = metalLayer.nextDrawable()
        }


        SceneKitVideoRecorder.frameRenderSemaphore.wait()


        guard let pool = self.pixelBufferAdaptor.pixelBufferPool else { return }

        let (pixelBufferTemp, image) = PixelBufferFactory.make(with: currentDrawable!, usingBuffer: pool)
        currentDrawable = nil
        guard let pixelBuffer = pixelBufferTemp else { return }
        currentTime = CFAbsoluteTimeGetCurrent() - initialTime

        let millisElapsed = NSDate().timeIntervalSince(audioCaptureStartedAt! as Date) * Double(options.timeScale)
        
        let presentationTime = CMTimeAdd(firstAudioTimestamp!, CMTimeMake(Int64(millisElapsed), Int32(options.timeScale)))

        SceneKitVideoRecorder.bufferAppendSemaphore.wait()
        bufferQueue.async { [weak self] in
          if self?.videoFramesWritten == false { self?.videoFramesWritten = true }
          self?.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime)
          SceneKitVideoRecorder.bufferAppendSemaphore.signal()
        }
        updateFrameHandler?(image, presentationTime)
      }
      SceneKitVideoRecorder.frameRenderSemaphore.signal()
    }

    private var audioCaptureStartedAt: NSDate?
    private var firstAudioTimestamp: CMTime?

    public func captureOutput(_ output: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
      if(audioCaptureStartedAt == nil) {
        audioCaptureStartedAt = NSDate()
        firstAudioTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      }
      if(audioInput.isReadyForMoreMediaData && isRecording && videoFramesWritten){
        audioInput.append(sampleBuffer)
      }
    }


    private func stopDisplayLink() {
      displayLink?.invalidate()
      displayLink = nil
    }
  }

#endif


