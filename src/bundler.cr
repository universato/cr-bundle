require "compiler/crystal/syntax"
require "compiler/crystal/formatter"

module CrBundle
  class Bundler
    def initialize(@options : Options)
      @require_history = Deque(Path).new
    end

    private macro check_path(path)
      %path = ({{path}}).to_s
      %path += ".cr" unless %path.ends_with?(".cr")
      return Path[File.expand_path(%path)] if File.exists?(%path)
    end

    private def collect_files(dir : Path, rec : Bool) : Array(Path)
      files = [] of Path
      Dir.each_child(dir.to_s) do |file|
        file = dir / file
        if File.directory?(file)
          files.concat collect_files(file, rec) if rec
        else
          files.push file if file.extension == ".cr"
        end
      end
      files
    end

    # see: https://crystal-lang.org/reference/syntax_and_semantics/requiring_files.html
    private def find_path(path : Path, relative_to : Path) : Path | Array(Path) | Nil
      is_relative = path.to_s.starts_with?(".")
      includes_slash = path.to_s.includes?('/')
      if path.extension == ".cr"
        check_path relative_to / path
      elsif (rec = path.to_s.ends_with?("/**")) || path.to_s.ends_with?("/*")
        return collect_files(relative_to / path.dirname, rec)
      elsif !is_relative && !includes_slash
        check_path relative_to / path
        check_path relative_to / path / path
        check_path relative_to / path / "src" / path
        check_path relative_to / path / "src" / path / path
      elsif !is_relative && includes_slash
        before, after = path.to_s.split('/', 2)
        check_path relative_to / path
        check_path relative_to / path / path.basename
        check_path relative_to / before / "src" / after
        check_path relative_to / before / "src" / after / path.basename
      elsif is_relative && !includes_slash
        check_path relative_to / path
        check_path relative_to / path / path.basename
      else # if is_relative && includes_slash
        check_path relative_to / path
        check_path relative_to / path / path.basename
      end
      return nil
    end

    private def get_absolute_paths(path : Path, required_from : Path) : Array(Path)?
      result = if path.to_s.starts_with?('.')
                 find_path(path, Path[required_from.dirname])
               else
                 @options.paths.flat_map { |relative_to| find_path(path, relative_to) || Array(Path).new }
               end
      case result
      when Path
        [result]
      when Array(Path)
        result.empty? ? nil : result
      end
    end

    private def detect_requires(ast : Crystal::ASTNode) : Array({String, Crystal::Location})
      result = [] of {String, Crystal::Location}
      case ast
      when Crystal::Expressions
        ast.expressions.each do |child|
          result.concat detect_requires(child)
        end
      when Crystal::Require
        result << {ast.string, ast.location.not_nil!}
      end
      result
    end

    def bundle(source : String, file_name : Path) : String
      @require_history << file_name

      parser = Crystal::Parser.new(source)
      parser.filename = file_name.to_s

      requires = detect_requires(parser.parse)
      expanded_codes = requires.map do |path, location|
        if absolute_paths = get_absolute_paths(Path[path], file_name)
          %[# require "#{path}"\n] + absolute_paths.sort.join('\n') { |absolute_path|
            unless @require_history.includes?(absolute_path)
              bundle(File.read(absolute_path), absolute_path)
            else
              ""
            end
          }
        else
          %[require "#{path}"]
        end
      end

      lines = source.lines
      requires.zip(expanded_codes).sort_by do |(path, location), expanded|
        location
      end.reverse_each do |(path, location), expanded|
        string = lines[location.line_number - 1]
        start_index = location.column_number - 1
        end_index = string[start_index..].match(/require\s*".*?"/).not_nil!.end.not_nil! + start_index
        lines[location.line_number - 1] = string.sub(start_index...end_index, expanded)
      end
      bundled = lines.join('\n')
      @options.format ? Crystal.format(bundled, file_name.to_s) : bundled
    end

    def dependencies(source : String, file_name : Path) : Array(Path)
      parser = Crystal::Parser.new(source)
      parser.filename = file_name.to_s
      detect_requires(parser.parse).flat_map do |path, location|
        get_absolute_paths(Path[path], file_name) || ([] of Path)
      end
    end
  end
end
