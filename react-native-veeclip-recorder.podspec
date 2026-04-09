require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-veeclip-recorder"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => "15.1" } 
  s.source       = { :git => "https://github.com/ARYA-KH003/react-native-veeclip-recorder.git", :tag => "#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm,swift,cpp}"
  s.homepage     = "https://github.com/facebook/react-native"
  
  s.dependency "React-Core"
  
  # 👇 CRITICAL: This allows us to intercept WebRTC frames
  s.dependency "react-native-webrtc" 
end