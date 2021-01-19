class Importer
  attr_accessor :access_token, :record_type
  class << self
    def load_data(record_type)
      record = record_model(record_type)
      record.destroy_all

      record.new.load_xml_data
    end

    def parse_data(record_type)
      CommunityRecord.where(data_type: record_type.to_s).destroy_all

      record = record_model(record_type)
      record.last.parse_data
    end

    def send_data(record_type)
      all_options = Rails.application.credentials.target_servers
      CommunityRecord.where(data_type: record_type.to_s).group_by(&:title).each do |target_server_name, records|
        records.each do |record|
          data_to_send = record.json_data
          options = all_options[target_server_name.to_sym]

          send_json_to_server(target_server_name, options, data_to_send)
        end
      end
    end

    def record_model(record_type)
      case record_type
      when :poi
        PoiRecord
      when :event
        EventRecord
      end
    end

    def send_json_to_server(name, options, data_to_send)
      access_token = Authentication.new(name, options).access_token
      url = options[:target_server][:url]

      puts "Sending data to #{name}"

      ApiRequestService.new(url, nil, nil, data_to_send, { Authorization: "Bearer #{access_token}" }).post_request
    end
  end
end
