# VideoPowerProto
Simple Application for Testing Video Playback Power Consumption

This application sets up different types of video pipelines for the purposes of comparing power usage. The options available are reflective of the video pipeline options used by Firefox. No actual power monitoring is done within the application; use a tool like Intel Power Gadget, or the macOS Activity Monitor for that.

## Pipeline Options
### Layer Class
This popup provides a way to choose the way that the video samples are displayed.
* CALayer: Display the video content in a `CALayer`, using the `setContents` method.
* AVSampleBufferDisplayLayer: Display the video content in a `AVSampleBufferDisplayLayer`, using the `enqueueSampleBuffer` method.

### Buffering
This popup determines how the decoded samples are processed before they are displayed in the layer.
* Direct: Do as little processing of samples as possible before putting them into the layer.
* Recreated: Each sample is denatured into raw pixel data, then recreated as a `CVPixelBuffer` before displaying it. When recreated, the Pixel Buffer Attributes (below) are applied again.

### Pixel Buffer Attributes
The Core Animation API allows a `CVPixelBuffer` to be [annotated with attributes](https://developer.apple.com/documentation/corevideo/cvpixelbuffer/pixel_buffer_attribute_keys?language=objc) that affect how the buffers are processed by other API calls.

## Future Work
* Embed videos of different codecs as assets into the project; add a popup menu to select amongst them.
* Add label to display details of the currently playing video.
* Add more pixel buffer attribute options.
