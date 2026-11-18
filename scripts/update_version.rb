require 'json'

abort 'Usage: ruby scripts/update_version.rb <version>' unless ARGV.length == 1
version = JSON.generate(ARGV.fetch(0))
root = File.expand_path('..', __dir__)

{
  'moon.mod' => /^version = .*$/,
  'src/cmd/main/version.mbt' => /^const VERSION = .*$/,
}.each do |path, pattern|
  path = File.join(root, path)
  source = File.read(path)
  abort "Expected exactly one version in #{path}" unless source.scan(pattern).length == 1
  source.sub!(pattern) { |line| "#{line.split(' = ', 2).first} = #{version}" }
  File.write(path, source)
end
