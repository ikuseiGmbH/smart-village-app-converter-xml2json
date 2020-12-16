class Importer
  attr_accessor :access_token, :record_type

  # Steps for Importer
  # - Load Login Credentials from server
  # - Load xml Data from tmb-url
  # - Parse XML Data to Hash
  # - send JSON Data to server
  # - save response from server an log it
  # - send notifications
  def initialize(record_type, target_server_name)
    options = Rails.application.credentials.target_servers[target_server_name]

    @record_type = record_type
    puts "Record type defined: #{@record_type}"

    @record = new_record
    puts "Record initialized"

    @record.load_xml_data
    puts "Data loaded from TMB"

    data_to_send = @record.convert_xml_to_hash(target_server_name, options)
    puts "Data converted for #{target_server_name}"

    send_json_to_server(target_server_name, options, data_to_send)
    puts "Data send to server"
  end

  def new_record
    case @record_type
    when :poi
      PoiRecord.new
    when :event
      EventRecord.new
    end
  end

  def send_json_to_server(name, options, data_to_send)
    access_token = Authentication.new(name, options).access_token
    url = options[:target_server][:url]

    puts "Sending data to #{name}"

    result = ApiRequestService.new(url, nil, nil, data_to_send, { Authorization: "Bearer #{access_token}" }).post_request
    @record.update(updated_at: Time.now, audit_comment: result.body)
  end
end
