// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import UniformTypeIdentifiers
import AVKit
import MediaPipeTasksVision

class MediaLibraryViewController: DetectorViewController {
  
  private struct Constants {
    static let inferenceTimeIntervalMs: Int64 = 300
    static let kMilliSeconds: Int64 = 1000
    static let savedPhotosNotAvailableText = "Saved photos album is not available."
    static let mediaEmptyText =
    "Click + to add an image or a video to begin running the object detection."
    static let pickFromGalleryButtonInset: CGFloat = 10.0
  }
  
  private lazy var pickerController = UIImagePickerController()
  private var playerViewController: AVPlayerViewController?
  private var objectDetectorService: ObjectDetectorService?
  
  private var playerTimeObserverToken : Any?
  
  @IBOutlet weak var pickFromGalleryButton: UIButton!
  @IBOutlet weak var progressView: UIProgressView!
  @IBOutlet weak var imageEmptyLabel: UILabel!
  @IBOutlet weak var pickedImageView: UIImageView!
  @IBOutlet weak var pickFromGalleryButtonBottomSpace: NSLayoutConstraint!
  
  override func viewDidLoad() {
    super.viewDidLoad()
  }
  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    redrawBoundingBoxesForCurrentDeviceOrientation()
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    interfaceUpdatesDelegate?.shouldClicksBeEnabled(true)
    
    guard UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) else {
     pickFromGalleryButton.isEnabled = false
     self.imageEmptyLabel.text = Constants.savedPhotosNotAvailableText
     return
    }
    pickFromGalleryButton.isEnabled = true
    self.imageEmptyLabel.text = Constants.mediaEmptyText
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    clearPlayerView()
    if objectDetectorService?.runningMode == .video {
      overlayView.clear()
    }
    objectDetectorService = nil
  }
  
  @IBAction func onClickPickFromGallery(_ sender: Any) {
    interfaceUpdatesDelegate?.shouldClicksBeEnabled(true)
    configurePickerController()
    present(pickerController, animated: true)
  }
    
  private func configurePickerController() {
    pickerController.delegate = self
    pickerController.sourceType = .savedPhotosAlbum
    pickerController.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    pickerController.allowsEditing = false
  }
  
  private func addPlayerViewControllerAsChild() {
    guard let playerViewController = playerViewController else {
      return
    }
    playerViewController.view.translatesAutoresizingMaskIntoConstraints = false
    
    self.addChild(playerViewController)
    self.view.addSubview(playerViewController.view)
    self.view.bringSubviewToFront(self.overlayView)
    self.view.bringSubviewToFront(self.pickFromGalleryButton)
    NSLayoutConstraint.activate([
      playerViewController.view.leadingAnchor.constraint(
        equalTo: view.leadingAnchor, constant: 0.0),
      playerViewController.view.trailingAnchor.constraint(
        equalTo: view.trailingAnchor, constant: 0.0),
      playerViewController.view.topAnchor.constraint(
        equalTo: view.topAnchor, constant: 0.0),
      playerViewController.view.bottomAnchor.constraint(
        equalTo: view.bottomAnchor, constant: 0.0)
    ])
    playerViewController.didMove(toParent: self)
  }
  
  private func removePlayerViewController() {
    defer {
      playerViewController?.view.removeFromSuperview()
      playerViewController?.willMove(toParent: nil)
      playerViewController?.removeFromParent()
    }
    removeObservers(player: playerViewController?.player)
    playerViewController?.player?.pause()
    playerViewController?.player = nil
  }
  
  private func removeObservers(player: AVPlayer?) {
    guard let player = player else {
      return
    }
    
    if let timeObserverTokern = playerTimeObserverToken {
      player.removeTimeObserver(timeObserverTokern)
      playerTimeObserverToken = nil
    }
    
    guard let playerItem = player.currentItem else {
      return
    }
    NotificationCenter.default.removeObserver(
      self,
      name: .AVPlayerItemDidPlayToEndTime,
      object: playerItem)
  }

  private func openMediaLibrary() {
    configurePickerController()
    present(pickerController, animated: true)
  }
  
  private func clearPlayerView() {
    imageEmptyLabel.isHidden = false
    removePlayerViewController()
  }
  
  private func showProgressView() {
    guard let progressSuperview = progressView.superview?.superview else {
      return
    }
    progressSuperview.isHidden = false
    progressView.progress = 0.0
    progressView.observedProgress = nil
    self.view.bringSubviewToFront(progressSuperview)
  }
  
  private func hideProgressView() {
    guard let progressSuperview = progressView.superview?.superview else {
      return
    }
    self.view.sendSubviewToBack(progressSuperview)
    self.progressView.superview?.superview?.isHidden = true
  }
  
  func layoutUIElements(withInferenceViewHeight height: CGFloat) {
    pickFromGalleryButtonBottomSpace.constant =
    height + Constants.pickFromGalleryButtonInset
    view.layoutSubviews()
  }
  
  func redrawBoundingBoxesForCurrentDeviceOrientation() {
    guard let objectDetectorService = objectDetectorService else {
      return
    }
    if objectDetectorService.runningMode == .image {
      overlayView
        .redrawObjectOverlays(
          forNewDeviceOrientation: UIDevice.current.orientation)
    }
  }
  
  deinit {
    playerViewController?.player?.removeTimeObserver(self)
  }
}

extension MediaLibraryViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  
  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
  
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    clearPlayerView()
    pickedImageView.image = nil
    overlayView.clear()
    
    picker.dismiss(animated: true)
    
    guard let mediaType = info[.mediaType] as? String else {
      return
    }
    
    switch mediaType {
    case UTType.movie.identifier:
      guard let mediaURL = info[.mediaURL] as? URL else {
        imageEmptyLabel.isHidden = false
        return
      }
      clearAndInitializeObjectDetectorService(runningMode: .video)
      let asset = AVAsset(url: mediaURL)
      Task {
        interfaceUpdatesDelegate?.shouldClicksBeEnabled(false)
        showProgressView()
        let resultBundle = await self.objectDetectorService?.detect(
          videoAsset:asset,
          inferenceIntervalMs: Double(Constants.inferenceTimeIntervalMs))
        hideProgressView()
        
        playVideo(mediaURL: mediaURL, resultBundle: resultBundle)
      }
      imageEmptyLabel.isHidden = true
    case UTType.image.identifier:
      guard let image = info[.originalImage] as? UIImage else {
        imageEmptyLabel.isHidden = false
        break
      }
      pickedImageView.image = image
      imageEmptyLabel.isHidden = true
      
      showProgressView()
      
      clearAndInitializeObjectDetectorService(runningMode: .image)
      
      DispatchQueue.global(qos: .userInteractive).async { [weak self] in
        guard let weakSelf = self,
              let objectDetectorResult = weakSelf
                .objectDetectorService?
                .detect(image: image)?
                .objectDetectorResults.first as? ObjectDetectorResult else {
          DispatchQueue.main.async {
            self?.hideProgressView()
          }
          return
        }
          
        DispatchQueue.main.async {
          weakSelf.hideProgressView()
          weakSelf.draw(
            detections: objectDetectorResult.detections,
            originalImageSize: image.size,
            andOrientation: image.imageOrientation)
        }
      }
    default:
      break
    }
  }
  
  func clearAndInitializeObjectDetectorService(runningMode: RunningMode) {
    objectDetectorService = nil
    switch runningMode {
      case .image:
        objectDetectorService = ObjectDetectorService
          .stillImageDetectorService(
            model: DetectorMetadata.sharedInstance.model,
            maxResults: DetectorMetadata.sharedInstance.maxResults,
            scoreThreshold: DetectorMetadata.sharedInstance.scoreThreshold)
      case .video:
        objectDetectorService = ObjectDetectorService
          .videoObjectDetectorService(
            model: DetectorMetadata.sharedInstance.model,
            maxResults: DetectorMetadata.sharedInstance.maxResults,
            scoreThreshold: DetectorMetadata.sharedInstance.scoreThreshold,
            videoDelegate: self)
      default:
        break;
    }
  }
  
  private func playVideo(mediaURL: URL, resultBundle: ResultBundle?) {
    playVideo(asset: AVAsset(url: mediaURL))
    playerTimeObserverToken = playerViewController?.player?.addPeriodicTimeObserver(
      forInterval: CMTime(value: Constants.inferenceTimeIntervalMs,
                          timescale: Int32(Constants.kMilliSeconds)),
      queue: DispatchQueue(label: "timeObserverQueue", qos: .userInteractive),
      using: { [weak self] (time: CMTime) in
        DispatchQueue.main.async {
          let index =
            Int(CMTimeGetSeconds(time) * Double(Constants.kMilliSeconds) / Double(Constants.inferenceTimeIntervalMs))
          guard
                let weakSelf = self,
                let resultBundle = resultBundle,
                index < resultBundle.objectDetectorResults.count,
                let objectDetectorResult = resultBundle.objectDetectorResults[index] else {
            return
          }
          weakSelf.draw(
            detections: objectDetectorResult.detections,
            originalImageSize: resultBundle.size,
            andOrientation: .up)
        }
    })
  }
  
  private func playVideo(asset: AVAsset) {
    if playerViewController == nil {
      let playerViewController = AVPlayerViewController()
      self.playerViewController = playerViewController
    }
    
    let playerItem = AVPlayerItem(asset: asset)
    if let player = playerViewController?.player {
      player.replaceCurrentItem(with: playerItem)
    }
    else {
      playerViewController?.player = AVPlayer(playerItem: playerItem)
    }
    
    playerViewController?.showsPlaybackControls = false
    addPlayerViewControllerAsChild()
    
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(self.playerDidFinishPlaying),
                   name: .AVPlayerItemDidPlayToEndTime,
                   object: playerItem
      )
    playerViewController?.player?.play()
  }
  
  @objc func playerDidFinishPlaying(notification: NSNotification) {
    overlayView.clear()
    interfaceUpdatesDelegate?.shouldClicksBeEnabled(true)
  }
}

extension MediaLibraryViewController: ObjectDetectorServiceVideoDelegate {
  
  func objectDetectorService(
    _ objectDetectorService: ObjectDetectorService,
    didFinishDetectionOnVideoFrame index: Int) {
    progressView.observedProgress?.completedUnitCount = Int64(index + 1)
  }
  
  func objectDetectorService(
    _ objectDetectorService: ObjectDetectorService,
    willBeginDetection totalframeCount: Int) {
    progressView.observedProgress = Progress(totalUnitCount: Int64(totalframeCount))
  }
}


