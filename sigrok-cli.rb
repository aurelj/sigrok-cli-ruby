#!/usr/bin/env ruby

require 'sigrok'
require 'optparse'
require 'ostruct'

include Sigrok

VERSION = '0.1'
BLOCK_SIZE = 4096

options = OpenStruct.new
opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: sigrok-cli.rb [options]"

    opts.separator ""
    opts.separator "Specific options:"

    opts.on("-V", "--version", "Show version") { options.version = true }
    opts.on("-l", "--loglevel [LEVEL]", Integer, "Set log level") { |l| options.loglevel = l }
    opts.on("-d", "--driver [DRIVER]", "The driver to use") { |d| options.driver = d }
    opts.on("-c", "--config [CONFIG]", "Specify device configuration options") { |c| options.config = c }
    opts.on("-i", "--input-file [FILENAME]", "Load input from file") { |i| options.input_file = i }
    opts.on("-I", "--input-format [FORMAT]", "Input format") { |i| options.input_format = i }
    opts.on("-o", "--output-file [FILENAME]", "Save output to file") { |o| options.output_file = o }
    opts.on("-O", "--output-format [FORMAT]", "Output format") { |o| options.output_format = o }
    opts.on("-C", "--channels [LIST]", "Channels to use") { |c| options.channels = c }
    opts.on("-g", "--channel-group [GROUP]", "Channel groups") { |g| options.channel_group = g }
    opts.on("--scan", "Scan for devices") { options.scan = true }
    opts.on("--show", "Show device detail") { options.show = true }
    opts.on("--time [TIME]", "How long to sample (ms)") { |t| options.time = t }
    opts.on("--samples [NUMBER]", "Number of samples to acquire") { |s| options.samples = s }
    opts.on("--frames [NUMBER]", "Number of frames to acquire") { |f| options.frames = f }
    opts.on("--continuous", "Sample continuously") { options.continuous = true }
    opts.on("--get [CONFIG]", "Get device option only") { |c| options.get = c }
    opts.on("--set", "Set device options only") { options.set = true }
end
opt_parser.parse!(ARGV)

if (not (options.version \
     or options.scan \
     or (options.driver and (options.show or options.get or options.set \
                          or options.time or options.samples \
                          or options.frames or options.continuous)) \
     or options.input_file))
    puts opt_parser.help
    exit 1
end

context = Context.create

if options.version
    puts ARGV[0], VERSION
    puts "using libsigrok #{context.package_version} (libversion #{context.lib_version})"

    puts "\nSupported hardware drivers:"
    context.drivers.each_value do |driver|
        puts driver.name, driver.long_name
    end

    puts "\nSupported input formats:"
    context.input_formats.each_value do |input|
        puts input.name, input.description
    end

    puts "\nSupported output formats:"
    context.output_formats.each_value do |output|
        puts output.name, output.description
    end

    exit 0
end

if options.loglevel
    context.log_level = LogLevel.get(options.loglevel)
end

def print_device_info(device)
    conn = ""
    if device.config_keys.include? ConfigKey.CONN
        conn = ":conn=#{device.config_get(ConfigKey.CONN)}"
    end
    puts "#{device.driver.name}#{conn} - #{[device.vendor, device.model, device.version].select{|s| s.size>0}.join(' ')} with #{device.channels.count} channels: #{device.channels.map{|c| c.name}.join(' ')}"
end

if options.scan and not options.driver
    context.drivers.each_value do |driver|
        driver.scan.each do |device|
            print_device_info(device)
        end
    end
    exit 0
end

def show_device(device, channel_group = nil)
    keys = device.driver.config_keys
    puts "Driver functions:" if keys.any?
    keys.each { |k| puts "    #{k.description}" }

    keys = device.driver.scan_options
    puts "Scan options:" if keys.any?
    keys.each { |k| puts "    #{k.identifier}: #{k.description}" }

    print_device_info(device)

    puts "Channel groups:" if device.channel_groups.any?
    device.channel_groups.each do |name,cg|
        channels = "channel#{cg.channels.size > 1 ? 's' : ''}"
        cg.channels.each { |c| channels += " #{c.name}" }
        puts "    #{name}: #{channels}"
    end

    if channel_group
        cgl = "on channel group #{channel_group.name}"
        configurable = channel_group
    else
        cgl = "across all channel groups"
        configurable = device
    end

    keys = configurable.config_keys
    puts "Supported configuration options #{cgl}:" if keys.any?
    keys.each do |k|
        value = configurable.config_get(k) if configurable.config_check(k, Capability.GET)
        list = " (#{configurable.config_list(k)})" if configurable.config_check(k, Capability.LIST)
        puts "    #{k.identifier}: #{value}#{list}"
    end
end

def get_option(configurable, option)
    key = configurable.config_keys.find { |c| c.identifier == option }
    if not key
        puts "Unknown option #{option}"
    elsif not configurable.config_check(key, Capability.GET)
        puts "Failed to get #{option}"
    else
        puts "#{configurable.config_get(key)}"
    end
end

def select_channels(device, options)
    if options.channels
        enabled_channels = options.channels.split(',').map{|c| c.split('=').push("")[0..1]}.to_h
        device.channels.each do |c|
            c.enabled = enabled_channels.has_key? c.name
            name = enabled_channels[c.name]
            c.name = name if name and name.size > 0
        end
    end
end

def select_channel_group(device, options)
    device.channel_groups[options.channel_group] if options.channel_group and device.channel_groups
end

device = nil
output = nil
output_file = nil

datafeed_in = lambda do |device, packet|
    if output.nil?
        if options.output_file
            options.output_format = "srzip" if not options.output_format
            output_file = open(options.output_file, 'w')
        else
            options.output_format = 'bits' if not options.output_format
            output_file = STDOUT
        end

        output_format = context.output_formats[options.output_format]
        if options.output_file
            output = output_format.create_output(options.output_file, device)
        else
            output = output_format.create_output(device)
        end
    end

    output_file.write(output.receive(packet))
end

if options.input_file

    if options.input_format
        input_spec = options.input_format.split(':')
        input_options = {}
        input_spec[1..-1].each do |pair|
            name, value = pair.split('=')
            key = ConfigKey.get_by_identifier(name)
            input_options[name] = key.parse_string(value)
        end
        input = context.input_formats[input_spec[0]].create_input(input_options)
    else
        begin
            session = context.load_session(options.input_file)
            device = session.devices[0]
            select_channels(device, options)
        rescue RuntimeError
            input = context.open_file(options.input_file)
        end
    end

    if device.nil?    # not a session input file
        session = context.create_session()
        session.add_datafeed_callback(datafeed_in)
        File.foreach(options.input_file, nil, BLOCK_SIZE) do |data|
            input.send(data)
            if device.nil?
                begin
                    input.device
                rescue RuntimeError
                else
                    device = input.device
                    select_channels(device, options)
                    session.add_device(device)
                end
            end
        end
        input.end
        exit 0
    end

elsif options.driver

    driver_spec = options.driver.split(':')
    driver_options = {}
    driver_spec[1..-1].each do |pair|
        name, value = pair.split('=')
        key = ConfigKey.get_by_identifier(name)
        driver_options[name] = key.parse_string(value)
    end
    devices = context.drivers[driver_spec[0]].scan(driver_options)
    exit 1 if devices.empty?

    if options.scan
        devices.each { |d| print_device_info(d) }
        exit 0
    end

    device = devices[0]
    device.open
    select_channels(device, options)
    channel_group = select_channel_group(device, options)

    if options.show
        show_device(device, channel_group)
        exit 0
    end

    { ConfigKey.LIMIT_MSEC    => 'time',
      ConfigKey.LIMIT_SAMPLES => 'samples',
      ConfigKey.LIMIT_FRAMES  => 'frames' }.each do |key, name|
        value = options[name]
        device.config_set(key, key.parse_string(value)) if value
    end

    if options.config
        options.config.split(':').each do |pair|
            name, value = pair.split('=')
            key = ConfigKey.get_by_identifier(name)
            (channel_group || device).config_set(key, key.parse_string(value))
        end
    end

    if options.get
        get_option(channel_group || device, options.get)
    end

    if options.get or options.set
        device.close
        exit 0
    end

    session = context.create_session()
    session.add_device(device)
end

session.add_datafeed_callback(datafeed_in)
session.start()

Signal.trap("INT") { session.stop } if options.continuous
session.run
device.close
