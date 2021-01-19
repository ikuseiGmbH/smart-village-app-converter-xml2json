# frozen_string_literal: true

class PoiRecord < Record

  # Load poi data from external source
  # and save it to local attribute 'xml_data'
  #
  # @return [XML] XML - Data
  def load_xml_data
    url = Rails.application.credentials.poi_source[:url]
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
    @base_file_url = @xml_doc.at_xpath("/result/@fileUrl").try(:value)
    potential_target_servers = Rails.application.credentials.target_servers

    @xml_doc.xpath("/result/poi").each do |xml_poi|
      location = parse_location(xml_poi)
      next unless record_valid?(xml_poi, location)

      matching_target_servers = select_target_servers(location, potential_target_servers)
      next if matching_target_servers.blank?

      if xml_poi.xpath("tours/tour").present?
        data_to_store =  { tours: [parse_single_tour_from_xml(xml_poi, location)] }
      else
        data_to_store = { point_of_interests: [parse_single_poi_from_xml(xml_poi, location)] }
      end

      matching_target_servers.each do |target_server|
        CommunityRecord.create(title: target_server, data_type: "poi", json_data: data_to_store)
      end
    end

    true
  end

  def parse_single_poi_from_xml(poi, location)
    poi_data = {
      name: poi.attributes["name"].try(:value),
      description: poi.xpath("description/text/div").try(:to_s),
      mobile_description: poi.xpath("descriptionMobileSingle/text/div").try(:to_s),
      category_name: parse_categories(poi).first,
      addresses: parse_addresses(poi),
      contact: parse_contact(poi.xpath("connections")),
      location: location,
      media_contents: parse_media_contents(poi),
      price_informations: parse_price_informations(poi),
      opening_hours: parse_opening_hours(poi),
      tags: parse_tags(poi),
      certificates: parse_certificates(poi),
      accessibility_information: parse_accessibility(poi)
    }

    operating_company = parse_operating_company(poi)
    poi_data[:operating_company] = operating_company if operating_company.present?
    poi_data
  end

  def parse_single_tour_from_xml(tour, location)
    tour_data = {
      name: tour.attributes["name"].try(:value),
      description: tour.xpath("description/text/div").try(:to_s),
      mobile_description: tour.xpath("descriptionMobileSingle/text/div").try(:to_s),
      category_name: parse_categories(tour).first,
      addresses: parse_addresses(tour),
      contact: parse_contact(tour.xpath("connections")),
      location: location,
      media_contents: parse_media_contents(tour),
      tags: parse_tags(tour),
      certificates: parse_certificates(tour),
      accessibility_information: parse_accessibility(tour),
      length_km: parse_length_km(tour).to_i,
      geometry_tour_data: parse_geometry_tour_data(tour)
    }

    operating_company = parse_operating_company(tour)
    tour_data[:operating_company] = operating_company if operating_company.present?
    tour_data
  end

  private

    # Prüfe anhand der Daten ob der Eintrag importiert werden soll
    # - Englische Inhalte sollen nicht importiert werden
    #
    # @param [Nokogiri::Node] xml_poi Ein Knoten im XML Dokument
    #
    # @return [Boolean] true wenn der Eintrag valide ist
    def record_valid?(xml_poi, location)
      return false unless xml_poi.attributes["language"].text == "de"

      true
    end

    # Parsing poi data for tag information
    #
    # @param [XML] XML part of an poi
    #
    # @return [Array] Array of Certificate Objects
    def parse_certificates(xml_part)
      cert_ids = xml_part.xpath("certificates/classification/@id").map(&:value)
      cert_ids.map { |c| find_certificate_by_id(c) }.compact
    end

    # Search XML for matching Certificates
    #
    # @param [Integer] cert_id ID of Certificate in XML
    #
    # @return [String] Name of certificate found in xml
    def find_certificate_by_id(cert_id)
      cert_node = @xml_doc.xpath("/result/classification[@id='#{cert_id}']").first
      return nil if cert_node.blank?

      certificate_name = cert_node.attributes["name"].try(:value)
      { name: certificate_name }
    end

    # Parsing poi data for tag information
    #
    # @param [XML] XML part of an poi
    #
    # @return [Array] List of names of tags of xml-data
    def parse_tags(xml_part)
      tag_ids = xml_part.xpath("tags/attribute/@id").map(&:value)
      tag_ids.map { |c| find_tag_by_id(c) }
    end

    # Search XML for matching Tag
    #
    # @param [Integer] cat_id ID of Category in XML
    #
    # @return [String] Name of tag found in xml
    def find_tag_by_id(tag_id)
      tag = @xml_doc.xpath("/result/attribute[@id='#{tag_id}']").first
      tag.attributes["name"].try(:value) if tag.present?
    end

    # Parsing poi data for category information
    #
    # @param [XML] XML part of an poi
    #
    # @return [Array] List of names of categories of xml-data
    def parse_categories(xml_part)
      cat_ids = xml_part.xpath("categories/classification/@id").map(&:value)
      cat_ids.map { |c| find_category_by_id(c) }
    end

    # Search XML for matching Category
    #
    # @param [Integer] cat_id ID of Category in XML
    #
    # @return [String] Name of category found in xml
    def find_category_by_id(cat_id)
      @xml_doc.xpath("/result/classification[@id='#{cat_id}']").first.attributes["name"].try(:value)
    end

    def parse_addresses(xml_part)
      address_data = []
      address_data << parse_default_addresses(xml_part)
      address_data << parse_tour_address(xml_part, "tourStart")
      address_data << parse_tour_address(xml_part, "tourEnd")
      address_data.compact.flatten
    end

    def parse_default_addresses(xml_part)
      address_data = xml_part.xpath("addresses/address").inject([]) do |memo, address|
        coordinates = address.xpath("coordinates/coordinate[@cos='latlng']").first
        lat = coordinates.try(:at_xpath, "x").try(:text)
        lng = coordinates.try(:at_xpath, "y").try(:text)

        addr = {
          addition: address.at_xpath("addition").try(:text),
          city: address.at_xpath("location").try(:text),
          street: address.at_xpath("street").try(:text),
          zip: address.at_xpath("zip").try(:text),
          kind: "default"
        }

        addr[:geo_location] = geo_location_input(lat, lng) if lat.present? && lng.present?
        memo << addr
      end

      address_data
    end

    def parse_tour_address(xml_part, node)
      tour_node = get_tour(xml_part)
      return unless tour_node.present?

      case node
      when "tourStart"
        kind = "start"
      when "tourEnd"
        kind = "end"
      end

      address = tour_node.xpath(node)
      coordinates = address.xpath("coordinates/coordinate[@cos='latlng']").first
      lat = coordinates.try(:at_xpath, "x").try(:text)
      lng = coordinates.try(:at_xpath, "y").try(:text)

      return_value = {
        addition: address.at_xpath("addition").try(:text),
        city: address.at_xpath("location").try(:text),
        street: address.at_xpath("street").try(:text),
        zip: address.at_xpath("zip").try(:text),
        kind: kind
      }

      return_value[:geo_location] = geo_location_input(lat, lng) if lat.present? && lng.present?
      return_value
    end

    def parse_geometry_tour_data(xml_part)
      tour_node = get_tour(xml_part)
      geo_tour_data = tour_node.at_xpath("geom").try(:text).to_s.tr("^0-9,. ", "").split(",").map do |item|
        item.split(" ")
      end
      geometry_tour_data = geo_tour_data.inject([]) do |memo, geo_location|
        geo = {
          latitude: geo_location[0].to_f,
          longitude: geo_location[1].to_f
        }
        memo << geo
      end
      geometry_tour_data
    end

    def parse_length_km(xml_part)
      xml_part.xpath("tags/attribute[@id='83038']/value").try(:text)
    end

    #
    # Method to get the tour node from an id provided in tours/tour node inside a single poi node
    #
    # @param [<Type>] xml_part Nokogiri node
    #
    # @return [<Type>] tour_node for a poi node
    #
    def get_tour(xml_part)
      tour_node = xml_part.xpath("tours/tour").first
      return unless tour_node.present?

      tour_id = tour_node.attributes["id"].try(:value)
      @xml_doc.xpath("/result/tour[@id='#{tour_id}']").first if tour_id.present?
    end

    # Erwartet einen XML Knoten der als kinder
    # <connection> Elemente besitzt.
    # Diese Werden dann iterativ analysiert und dann ein Contact Hash daraus erzeugt
    #
    # @param [XML] xml_part Nokogiri-Node
    #
    # @return [Hash] Details of Contact and URLs
    def parse_contact(xml_part)
      contact = {}
      xml_part.xpath("connection").each do |connection|
        con_type = connection.at_xpath("type").try(:text)
        con_value = connection.at_xpath("information").try(:text)

        case con_type
        when "telefon"
          contact[:phone] = con_value
        when "telefax"
          contact[:fax] = con_value
        when "email"
          contact[:email] = con_value
        when "url", "urlInformation", "urlVideo", "urlVideopreview", "urlSocialmedia"
          contact[:webUrls] = [] if contact[:webUrls].blank?
          contact[:webUrls] << {
            url: add_missing_protocol(con_value),
            description: con_type
          }
        when "person"
          contact[:last_name] = con_value
        end
      end

      contact
    end

    # vendorAddress im TMB XML
    def parse_operating_company(xml_part)
      name = xml_part.at_xpath("vendorAddress/addition").try(:text)
      return if name.blank?

      {
        name: name,
        address: {
          addition: xml_part.at_xpath("vendorAddress/addition").try(:text),
          city: xml_part.at_xpath("vendorAddress/location").try(:text),
          street: xml_part.at_xpath("vendorAddress/street").try(:text),
          zip: xml_part.at_xpath("vendorAddress/zip").try(:text)
        },
        contact: parse_contact(xml_part.xpath("vendorContact"))
      }
    end

    # Parse Location Tag in xml-data
    #
    def parse_location(xml_part)
      location_id = xml_part.at_xpath("location/@id")
      location = @xml_doc.xpath("/result/location[@id='#{location_id}']").first

      return {} if location.blank?

      coordinates = location.xpath("coordinates/coordinate[@cos='latlng']").first
      lat = coordinates.try(:at_xpath, "x").try(:text)
      lng = coordinates.try(:at_xpath, "y").try(:text)

      return_value = {
        name: location.attributes["name"].try(:value),
        department: department_name_for_location(location),
        district: district_name_for_location(location),
        region_name: region_name_for_location(location),
        state: state_for_location(location)
      }

      return_value[:geo_location] = geo_location_input(lat, lng) if lat.present? && lng.present?
      return_value
    end

    def department_name_for_location(location)
      department_node = location.xpath("department/department").first
      department_ids = department_node.attributes["id"].try(:value) if department_node.present?
      department = @xml_doc.xpath("/result/department[@id='#{department_ids}']").first if department_ids.present?

      department.attributes["name"].try(:value) if department.present?
    end

    def district_name_for_location(location)
      district_node = location.xpath("district/district").first
      district_ids = district_node.attributes["id"].try(:value) if district_node.present?
      district = @xml_doc.xpath("/result/district[@id='#{district_ids}']").first if district_ids.present?

      district.attributes["name"].try(:value) if district.present?
    end

    def region_name_for_location(location)
      region_node = location.xpath("region/region").first
      region_ids = region_node.attributes["id"].try(:value) if region_node.present?
      region = @xml_doc.xpath("/result/region[@id='#{region_ids}']").first if region_ids.present?

      region.attributes["name"].try(:value) if region.present?
    end

    def state_for_location(location)
      state_node = location.xpath("state").first
      state_id = state_node.attributes["id"].try(:value) if state_node.present?
      state = @xml_doc.xpath("/result/state[@id='#{state_id}']").first if state_id.present?

      state.attributes["name"].try(:value) if state.present?
    end

    # BildURLS aus <gallery> und <thumbnail>
    # Alle Medien sind Referenzen zu dem XML-Tags <file>
    def parse_media_contents(xml_part)
      media_data = []

      thumbnail_id = xml_part.at_xpath("thumbnail/@id").try(:value)
      media_data << parse_file_for_id(thumbnail_id, "thumbnail")

      xml_part.xpath("gallery/file/@id").each do |file_id|
        media_data << parse_file_for_id(file_id, "image")
      end
      media_data
    end

    def parse_file_for_id(file_id, file_type)
      file = @xml_doc.xpath("/result/file[@id='#{file_id}']").first
      return default_media_content if file.blank?

      {
        source_url: {
          url: "#{@base_file_url}/#{file.attributes["id"].try(:value)}",
          description: file_type
        },
        caption_text: file.at_xpath("alt").try(:text),
        content_type: file_type
      }
    end

    def default_media_content
      {
        source_url: {
          url: "",
          description: "description"
        },
        caption_text: "",
        content_type: "image"
      }
    end

    def parse_price_informations(xml_part)
      price_data = []
      xml_part.xpath("price/pricerangecomplex").each do |price|
        amount = price.at_xpath("price").try(:text)
        age_from = price.at_xpath("agefrom").try(:text)
        age_to = price.at_xpath("ageto").try(:text)
        max_adult_count = price.at_xpath("adultcount").try(:text)
        max_children_count = price.at_xpath("childrencount").try(:text)

        price_data << {
          category: category_name_for_price(price),
          amount: amount.present? ? amount.delete(".").sub(",", ".").to_f : nil,
          age_from: age_from.present? ? age_from.to_i : nil,
          age_to: age_to.present? ? age_to.to_i : nil,
          description: price.at_xpath("description").try(:text),
          group_price: is_true?(price.at_xpath("groupprice").try(:text)),
          max_adult_count: max_adult_count.present? ? max_adult_count.to_i : nil,
          max_children_count: max_children_count.present? ? max_children_count.to_i : nil
        }
      end

      price_data
    end

    # Methode übergibt den wert der in pricecategory steht an die Translation Service Klasse,
    # die den englischen Kategorienamen ins Deutsche übersetzt.
    def category_name_for_price(price)
      price_category = price.at_xpath("category").try(:text)
      category_text = price.at_xpath("categorytext").try(:text)
      Translation.price_category(price_category, category_text)
    end

    def parse_opening_hours(xml_part)
      opening_hours = []
      xml_part.xpath("openinghours/openingtimedate").each_with_index do |opening_day, index|
        opening_hours << {
          weekday: Translation.weekday(opening_day.at_xpath("weekday").try(:text)),
          date_from: opening_day.at_xpath("datefrom").try(:text),
          date_to: opening_day.at_xpath("dateto").try(:text),
          time_from: opening_day.at_xpath("timefrom").try(:text),
          time_to: opening_day.at_xpath("timeto").try(:text),
          open: is_true?(opening_day.at_xpath("open").try(:text).try(:downcase)),
          sort_number: index
        }
      end

      other_opening_hour = xml_part.at_xpath("otheropeninghours").try(:text)
      opening_hours << { description: other_opening_hour } if other_opening_hour.present?

      opening_hours
    end

    def parse_accessibility(xml_part)
      return {} unless xml_part.at_xpath("hasDatasheet").try(:text) == "true"

      poi_id = xml_part.attributes["id"].try(:value)
      {
        description: "Barrierefreiheits-Informationen verfügbar",
        urls: [{
          url: "http://www.barrierefrei-brandenburg.de/index.php?id=dsview&tx_tmbpoisearch_pi2[poi]=#{poi_id}",
          description: "Informationen zur Barrierefreiheit finden sie unter diesem Link"}]
      }
    end

    def add_missing_protocol(url)
      return if url.blank?

      url.start_with?("www") ? "http://" + url : url
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
