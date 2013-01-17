Gem::Specification.new do |s|
  s.name        = 'rake_release'
  s.version     = '1.0.0'
  s.date        = '2010-04-28'
  s.summary     = "Adds release take to rake file"
  s.description = "Rev's tags etc Rakefile with VERSION_NUMBER for CI server"
  s.authors     = ["Brian Tanner"]
  s.email       = 'brian.tanner@gmail.com'
  s.files       = ["lib/rake_release.rb"]
  s.add_dependency 'builder', '3.1.3'
  s.add_dependency 'xml-simple', '~>1.0.12'
#  s.homepage    = 
end

