source 'https://cdn.cocoapods.org/'
platform :ios, '16.0'
project 'LanCinema.xcodeproj'
target 'LanCinema' do
  pod 'MobileVLCKit', '3.7.2'
  target 'LanCinemaTests' do
    inherit! :search_paths
  end
end
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
