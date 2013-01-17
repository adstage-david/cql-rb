# encoding: utf-8

require 'ipaddr'
require 'bigdecimal'
require 'set'


module Cql
  UnsupportedOperationError = Class.new(CqlError)
  UnsupportedFrameTypeError = Class.new(CqlError)
  UnsupportedResultKindError = Class.new(CqlError)
  UnsupportedColumnTypeError = Class.new(CqlError)

  class ResponseFrame
    def initialize(buffer='')
      @headers = FrameHeaders.new(buffer)
      check_complete!
    end

    def stream_id
      @headers && @headers.stream_id
    end

    def header_length
      8
    end

    def body_length
      @headers && @headers.length
    end

    def body
      @body.response
    end

    def complete?
      @body && @body.complete?
    end

    def <<(str)
      if @body
        @body << str
      else
        @headers << str
        check_complete!
      end
    end

    private

    def check_complete!
      if @headers.complete?
        @body = create_body
      end
    end

    def create_body
      body_type = begin
        case @headers.opcode
        when 0x00 then ErrorResponse
        when 0x02 then ReadyResponse
        when 0x06 then SupportedResponse
        when 0x08 then ResultResponse
        else
          raise UnsupportedOperationError, "The operation #{@headers.opcode} is not supported"
        end
      end
      FrameBody.new(@headers.buffer, @headers.length, body_type)
    end

    class FrameHeaders
      attr_reader :buffer, :protocol_version, :stream_id, :opcode, :length

      def initialize(buffer)
        @buffer = buffer
        check_complete!
      end

      def <<(str)
        @buffer << str
        check_complete!
      end

      def complete?
        !!@protocol_version
      end

      private

      def check_complete!
        if @buffer.length >= 8
          @protocol_version, @flags, @stream_id, @opcode, @length = @buffer.slice!(0, 8).unpack(HEADER_FORMAT)
          raise UnsupportedFrameTypeError, 'Request frames are not supported' if @protocol_version > 0
          @protocol_version &= 0x7f
        end
      end
    end

    class FrameBody
      attr_reader :response, :buffer

      def initialize(buffer, length, type)
        @buffer = buffer
        @length = length
        @type = type
        check_complete!
      end

      def <<(str)
        @buffer << str
        check_complete!
      end

      def complete?
        !!@response
      end

      private

      def check_complete!
        if @buffer.length >= @length
          @response = @type.decode!(@buffer)
        end
      end
    end
  end

  class ResponseBody
    extend Decoding

    def self.decode!(buffer)
    end
  end

  class ErrorResponse < ResponseBody
    attr_reader :code, :message

    def initialize(*args)
      @code, @message = args
    end

    def self.decode!(buffer)
      new(read_int!(buffer), read_string!(buffer))
    end

    def to_s
      %(ERROR #{code} "#{message}")
    end
  end

  class ReadyResponse < ResponseBody
    def self.decode!(buffer)
      new
    end

    def to_s
      'READY'
    end
  end

  class SupportedResponse < ResponseBody
    attr_reader :options

    def initialize(options)
      @options = options
    end

    def self.decode!(buffer)
      new(read_string_multimap!(buffer))
    end

    def to_s
      %(SUPPORTED #{options})
    end
  end

  class ResultResponse < ResponseBody
    attr_reader :change, :keyspace, :table, :rows

    def self.decode!(buffer)
      kind = read_int!(buffer)
      case kind
      when 0x01
        VoidResultResponse.decode!(buffer)
      when 0x02
        RowsResultResponse.decode!(buffer)
      when 0x03
        SetKeyspaceResultResponse.decode!(buffer)
      when 0x04
        PreparedResultResponse.decode!(buffer)
      when 0x05
        SchemaChangeResultResponse.decode!(buffer)
      else
        raise UnsupportedResultKindError, %(Unsupported result kind: #{kind})
      end
    end
  end

  class VoidResultResponse < ResultResponse
    def self.decode!(buffer)
      new
    end

    def to_s
      %(RESULT void)
    end
  end

  class RowsResultResponse < ResultResponse
    attr_reader :rows

    def initialize(rows)
      @rows = rows
    end

    def self.read_column_type!(buffer)
      id, type = read_option!(buffer) do |id, b|
        case id
        when 0x01 then :ascii
        when 0x02 then :bigint
        when 0x03 then :blob
        when 0x04 then :boolean
        # when 0x05 then :counter
        when 0x06 then :decimal
        when 0x07 then :double
        when 0x08 then :float
        when 0x09 then :int
        when 0x0a then :text
        when 0x0b then :timestamp
        when 0x0c then :uuid
        when 0x0d then :varchar
        when 0x0e then :varint
        when 0x0f then :timeuuid
        when 0x10 then :inet
        when 0x20
          sub_type = read_column_type!(buffer)
          [:list, sub_type]
        when 0x21
          key_type = read_column_type!(buffer)
          value_type = read_column_type!(buffer)
          [:map, key_type, value_type]
        when 0x22
          sub_type = read_column_type!(buffer)
          [:set, sub_type]
        else
          raise UnsupportedColumnTypeError, %(Unsupported column type: #{id})
        end
      end
      type
    end

    def self.read_metadata!(buffer)
      flags = read_int!(buffer)
      columns_count = read_int!(buffer)
      if flags & 0x01 == 0x01
        global_keyspace_name = read_string!(buffer)
        global_table_name = read_string!(buffer)
      end
      column_specs = columns_count.times.map do
        if global_keyspace_name
          keyspace_name = global_keyspace_name
          table_name = global_table_name
        else
          keyspace_name = read_string!(buffer)
          table_name = read_string!(buffer)
        end
        column_name = read_string!(buffer)
        type = read_column_type!(buffer)
        [keyspace_name, table_name, column_name, type]
      end
    end

    def self.convert_bignum(bytes)
      n = 0
      bytes.each_byte do |b|
        n = (n << 8) | b
      end
      n
    end

    def self.convert_bigdecimal(bytes)
      size = bytes.unpack(INT_FORMAT).first
      BigDecimal.new(convert_bignum(bytes[4, bytes.length - 4]), size)
    end

    def self.convert_type(bytes, type)
      return nil unless bytes
      case type
      when :ascii
        bytes.force_encoding(::Encoding::ASCII)
      when :bigint
        top, bottom = bytes.unpack(TWO_INTS_FORMAT)
        top << 32 | bottom
      when :blob
        bytes
      when :boolean
        bytes == TRUE_BYTE
      when :decimal
        convert_bigdecimal(bytes)
      when :double
        bytes.unpack(DOUBLE_FORMAT).first
      when :float
        bytes.unpack(FLOAT_FORMAT).first
      when :int
        bytes.unpack(INT_FORMAT).first
      when :timestamp
        top, bottom = bytes.unpack(TWO_INTS_FORMAT)
        ms = top << 32 | bottom
        Time.at(ms)
      when :varchar, :text
        bytes.force_encoding(::Encoding::UTF_8)
      when :varint
        convert_bignum(bytes)
      when :timeuuid, :uuid
        Uuid.new(convert_bignum(bytes))
      when :inet
        IPAddr.new_ntoh(bytes)
      when Array
        case type.first
        when :list
          list = []
          size = read_short!(bytes)
          size.times do
            list << convert_type(read_short_bytes!(bytes), type.last)
          end
          list
        when :map
          map = {}
          size = read_short!(bytes)
          size.times do
            key = convert_type(read_short_bytes!(bytes), type[1])
            value = convert_type(read_short_bytes!(bytes), type[2])
            map[key] = value
          end
          map
        when :set
          set = Set.new
          size = read_short!(bytes)
          size.times do
            set << convert_type(read_short_bytes!(bytes), type.last)
          end
          set
        end
      else
        bytes
      end
    end

    def self.read_rows!(buffer, column_specs)
      rows_count = read_int!(buffer)
      rows = []
      rows_count.times do |row_index|
        row = {}
        column_specs.each do |column_spec|
          column_value = read_bytes!(buffer)
          row[column_spec[2]] = convert_type(column_value, column_spec[3])
        end
        rows << row
      end
      rows
    end

    def self.decode!(buffer)
      column_specs = read_metadata!(buffer)
      new(read_rows!(buffer, column_specs))
    end

    def to_s
      %(RESULT rows ...)
    end

    private

    TWO_INTS_FORMAT = 'NN'.freeze
    DOUBLE_FORMAT = 'G'.freeze
    FLOAT_FORMAT = 'g'.freeze
    INT_FORMAT = 'N'.freeze
    TRUE_BYTE = "\x01".freeze
  end

  class SetKeyspaceResultResponse < ResultResponse
    attr_reader :keyspace

    def initialize(keyspace)
      @keyspace = keyspace
    end

    def self.decode!(buffer)
      new(read_string!(buffer))
    end

    def to_s
      %(RESULT set_keyspace "#{@keyspace}")
    end
  end

  class PreparedResultResponse < ResultResponse
    attr_reader :id, :metadata

    def initialize(*args)
      @id, @metadata = args
    end

    def self.decode!(buffer)
      id = read_short_bytes!(buffer)
      metadata = RowsResultResponse.read_metadata!(buffer)
      new(id, metadata)
    end

    def to_s
      %(RESULT prepared #{id.inspect})
    end
  end

  class SchemaChangeResultResponse < ResultResponse
    attr_reader :change, :keyspace, :table

    def initialize(*args)
      @change, @keyspace, @table = args
    end

    def self.decode!(buffer)
      new(read_string!(buffer), read_string!(buffer), read_string!(buffer))
    end

    def to_s
      %(RESULT schema_change "#{@change}" "#{@keyspace}" "#{@table}")
    end
  end
end