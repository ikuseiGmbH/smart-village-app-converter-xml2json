class EventRecord < Record

  # Load event data from external source
  # and save it to local attribute 'xml_data'
  #
  # @return [XML] XML - Data
  def load_xml_data
    url = Rails.application.credentials.event_source[:url]
    pem = Rails.application.credentials.tmb_auth[:pem]
    password = Rails.application.credentials.tmb_auth[:password]
    result = ApiRequestService.new(url).get_request(false, pem, password)

    return unless result.code == "200"
    return unless result.body.present?

    self.xml_data = result.body
    self.save
  end

  def parse_data
    @xml_doc = Nokogiri.XML(xml_data)
    @xml_doc.remove_namespaces!
    potential_target_servers = Rails.application.credentials.target_servers

    @xml_doc.xpath("/brandenburgevents/EVENT").each do |xml_event|
      location = parse_location(xml_event)

      matching_target_servers = select_target_servers(location, potential_target_servers)
      next if matching_target_servers.blank?

      data_to_store = { events: [parse_single_event_from_xml(xml_event, location)] }
      matching_target_servers.each do |target_server|
        CommunityRecord.create(title: target_server, data_type: "event", json_data: data_to_store)
      end
    end

    true
  end

  # Parse XML Data and converts it to a Hash
  #
  # @return [Hash] Hash of events
  def convert_xml_to_hash(name, options)
    event_data = []
    @xml_doc = Nokogiri.XML(xml_data)
    @xml_doc.remove_namespaces!
    @xml_doc.xpath("/brandenburgevents/EVENT").each do |xml_event|
      location = parse_location(xml_event)
      next unless record_valid?(xml_event, location, options)

      event_data << parse_single_event_from_xml(xml_event, location)
    end

    { events: event_data }
  end

  def parse_single_event_from_xml(event, location)
    event_data = {
      title: event.at_xpath("E_TITEL").try(:text),
      external_id: event.at_xpath("E_ID").try(:text),
      description: event.at_xpath("E_BESCHREIBUNG").try(:text),
      price_informations: [{ description: event.at_xpath("E_PREISTEXT").try(:text) }],
      category_name: event.at_xpath("KATEGORIE_NAME_D").try(:text),
      region_name: event.at_xpath("REGION_NAME_D").try(:text),
      accessibility_information: parse_accessibility(event),
      dates: parse_event_dates(event),
      urls: parse_urls(event),
      addresses: parse_address(event),
      contacts: parse_contact(event),
      location: location,
      media_contents: parse_media_content(event)
    }

    operating_company = parse_organizer(event)
    event_data[:organizer] = operating_company if operating_company.present?

    event_data
  end

  def parse_accessibility(event)
    {
      description: event.at_xpath("E_BARRIEREFREI_TEXT").try(:text),
      types: event.at_xpath("E_BARRIEREFREI_TYPES").try(:text),
      urls: [
        {
          url: event.at_xpath("E_BARRIEREFREI_URL").try(:text),
          description: event.at_xpath("E_BARRIEREFREI_URLDESC").try(:text)
        }
      ]
    }
  end

  def parse_event_dates(event)
    [
      {
        date_start: event.at_xpath("E_DATUM_VON").try(:text),
        time_start: event.at_xpath("E_ZEIT_VON").try(:text),
        date_end: event.at_xpath("E_DATUM_BIS").try(:text),
        time_end: event.at_xpath("E_ZEIT_BIS").try(:text),
        time_description: event.at_xpath("E_ZEIT_TEXT").try(:text),
        use_only_time_description: is_true?(event.at_xpath("E_NODATES").try(:text).try(:downcase))
      }
    ]
  end

  def parse_urls(event)
    urls = []

    if event.at_xpath("E_TICKETURL_D").try(:text).present?
      urls << {
        url: event.at_xpath("E_TICKETURL_D").try(:text),
        description: "Ticket URL"
      }
    end

    if event.at_xpath("E_URL1").try(:text).present?
      urls << {
        url: event.at_xpath("E_URL1").try(:text),
        description: event.at_xpath("E_URL1DESC").try(:text)
      }
    end

    if event.at_xpath("E_URL2").try(:text).present?
      urls << {
        url: event.at_xpath("E_URL2").try(:text),
        description: event.at_xpath("E_URL2DESC").try(:text)
      }
    end

    urls
  end

  def parse_address(event)
    return_value = {
      addition: event.at_xpath("E_LOC_NAME").try(:text),
      street: event.at_xpath("E_LOC_STRASSE").try(:text),
      zip: event.at_xpath("E_LOC_PLZ").try(:text),
      city: event.at_xpath("E_LOC_ORT").try(:text)
    }

    lat = event.at_xpath("E_GEOKOORD_LAT").try(:text)
    lng = event.at_xpath("E_GEOKOORD_LNG").try(:text)
    return_value[:geo_location] = geo_location_input(lat, lng) if lat.present? && lng.present?

    return_value
  end

  def parse_contact(event)
    {
      phone: event.at_xpath("E_LOC_TEL").try(:text),
      fax: event.at_xpath("E_LOC_FAX").try(:text),
      email: event.at_xpath("E_LOC_EMAIL").try(:text),
      web_urls: [
        {
          url: event.at_xpath("E_LOC_WEB").try(:text)
        }
      ]
    }
  end

  def parse_organizer(event)
    name = event.at_xpath("E_KONTAKT_FIRMA").try(:text)
    return if name.blank?

    {
      name: name,
      address: {
        addition: event.at_xpath("E_KONTAKT_NAME").try(:text),
        street: event.at_xpath("E_KONTAKT_STRASSE").try(:text),
        zip: event.at_xpath("E_KONTAKT_PLZ").try(:text),
        city: event.at_xpath("E_KONTAKT_ORT").try(:text)
      },
      contact: {
        phone: event.at_xpath("E_KONTAKT_TEL").try(:text),
        fax: event.at_xpath("E_KONTAKT_FAX").try(:text),
        email: event.at_xpath("E_KONTAKT_EMAIL").try(:text),
        web_urls: [
          {
            url: event.at_xpath("E_KONTAKT_WEB").try(:text)
          }
        ]
      }
    }
  end

  def parse_location(event)
    {
      region_name: event.at_xpath("REGION_NAME_D").try(:text),
      departments: event.at_xpath("TMBORTE_NAME").try(:text),
      district: event.at_xpath("REGION_NAME_D").try(:text),
    }
  end

  def parse_media_content(event)
    image_data = []

    if event.at_xpath("IMAGELINK_XL").try(:text).present?
      image_data << {
        content_type: "image",
        source_url: {
          url: event.at_xpath("IMAGELINK_XL").try(:text)
        },
        caption_text: event.at_xpath("E_PIC1ALT").try(:text),
      }
    end

    if event.at_xpath("IMAGELINK_2_XL").try(:text).present?
      image_data << {
        content_type: "image",
        source_url: {
          url: event.at_xpath("IMAGELINK_2_XL").try(:text)
        },
        caption_text: event.at_xpath("E_PIC2ALT").try(:text),
      }
    end

    if event.at_xpath("IMAGELINK_3_XL").try(:text).present?
      image_data << {
        content_type: "image",
        source_url: {
          url: event.at_xpath("IMAGELINK_3_XL").try(:text)
        },
        caption_text: event.at_xpath("E_PIC3ALT").try(:text),
      }
    end

    image_data
  end

  def record_valid?(event, location, options)
    return false if !options[:districts].include?(location[:district]) && !options[:departments].include?(location[:department])

    true
  end

end

# == Schema Information
#
# Table name: records
#
#  id          :bigint           not null, primary key
#  external_id :string
#  json_data   :jsonb
#  xml_data    :text
#  type        :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#
