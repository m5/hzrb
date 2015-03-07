require 'yaml'
require 'ap'
require 'set'
require 'json'

class LogEntry
  attr_accessor :ip, :params
  def initialize
    @params = {}
  end
end

class LogParser
  include Enumerable

  def initialize(logfile)
    @logfile = logfile
  end

  def each
    entry = LogEntry.new
    @logfile.each_line do |line|
      if line == "\n"
        yield entry if entry
        next
        entry = LogEntry.new
      end


      case(line.strip)
      when /^Processing/
        parse_processing(entry, line)
      when /^Parameters/
        parse_parameters(entry, line)
      when /^Completed/
        parse_completed(entry, line)
      end
    end
  end

  protected
  def parse_processing(entry, line)
    entry.ip = line.match(/for ([.0-9]*) at/).captures.first
  end

  def parse_parameters(entry, line)
    begin
      entry.params.merge!(eval(line.split(' ', 2).last))
    rescue Exception => e
      puts line
    end
  end

  def parse_completed(entry, line)
    entry.params["url"] = line.match(/\[(.*)\]$/).captures.first
  end
end

class Counter
  attr_accessor :name, :matcher, :uniques, :hits
  def initialize(name, matcher)
    @name = name
    @matcher = matcher 
    @hits = 0
    @uniques = Set.new
  end

  def track(entry)
    if @matcher.match?(entry) 
      @hits += 1
      @uniques << entry.ip
    end
  end
end

class FunnelStep
  attr_accessor :name, :children, :uniques
  def initialize(name, matcher, children)
    @uniques = Set.new
    @children = children
    @name = name
    @matcher = matcher
  end

  def track(entry)
    if @uniques.include?(entry.ip)
      @children.each{|c| c.track(entry)}
    elsif @matcher.match?(entry)
      @uniques << entry.ip 
    end
  end
end

class Matcher
  def initialize(params)
    @params = params.each_pair.map do |k,v|
      re_match = v.match(/^\/(.*)\/$/)
      v = /#{re_match.captures.first}/ if re_match
      [k, v]
    end
  end

  def match?(entry)
    # ap [@params, entry.params]
    @params.each.all? do |k, match| 
      if match.respond_to?(:match) && !entry.params[k].nil?
        entry.params[k].match(match)
      else
        match == entry.params[k] 
      end
    end 
  end
end

class Analyzer
  def initialize(config)
    @counters = config["counters"].each_pair.map do |name, matcher|
      Counter.new(name, Matcher.new(matcher)) 
    end

    @funnels = parse_funnels(config["funnels"])
  end

  def analyze(logfile)
    LogParser.new(logfile).each_with_index do |entry, idx|
      @counters.each{|c| c.track(entry)}
      @funnels.each{|c| c.track(entry)}
    end
  end

  def report
    puts "Counters:"
    @counters.each do |counter|
      puts "\t#{counter.name} - hits: #{counter.hits}, uniques: #{counter.uniques.size}"
    end

    puts "Funnels:"
    @funnels.each do |funnel|
      print_funnel(funnel)
    end
  end

  protected
  def print_funnel(funnel, level:0)
    puts ("\t" * (level + 1)) + "#{funnel.name} - hits: #{funnel.uniques.size}"
    funnel.children.each{|c| print_funnel(c, level:level+1) }
  end

  def parse_funnels(funnel_config)
    funnel_config.each_pair.map do |name, config|
      FunnelStep.new(name, Matcher.new(config["match"]), parse_funnels(config["children"]||{}))
    end
  end
end

if __FILE__ == $0
  analyzer = Analyzer.new(YAML.load(open(ARGV.shift).read))
  ARGV.each{|f| analyzer.analyze(open(f)) }
  analyzer.report
end
