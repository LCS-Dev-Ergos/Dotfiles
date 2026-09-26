# Build a machine-readable catalog from shdoc blocks placed directly above
# shell functions. Legacy blocks are retained only for migration diagnostics.
# Output fields are separated by the `sep` variable.

function trim(value) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}

function squash(value) {
  gsub(/[[:space:]]+/, " ", value)
  return trim(value)
}

function comment_text(line) {
  sub(/^[[:space:]]*#[[:space:]]?/, "", line)
  return line
}

function is_separator(value) {
  return value ~ /^[-=+][-=+[:space:]]*#?$/
}

function append_text(current, value) {
  value = squash(value)
  if (value == "") {
    return current
  }
  return current == "" ? value : current " " value
}

function safe(value) {
  gsub(sep, " ", value)
  gsub(/[\r\n]/, " ", value)
  return squash(value)
}

function completion_safe(value) {
  gsub(sep, " ", value)
  if (completion_item_sep != "") gsub(completion_item_sep, " ", value)
  if (completion_field_sep != "") gsub(completion_field_sep, " ", value)
  gsub(/[\r\n]/, " ", value)
  return squash(value)
}

function append_completion(current, name, type, description, item) {
  item = completion_safe(name) completion_field_sep \
         completion_safe(type) completion_field_sep \
         completion_safe(description)
  return current == "" ? item : current completion_item_sep item
}

function quality_score(value) {
  if (value == "standard") return 2
  if (value == "legacy") return 1
  return 0
}

function store_record(name, category, summary, usage, details, source, line,
                      quality, args, options, noargs, key, score) {
  key = name SUBSEP source
  score = quality_score(quality)
  if (!(key in record_score) || score > record_score[key]) {
    record_score[key] = score
    record_name[key] = safe(name)
    record_category[key] = safe(category)
    record_summary[key] = safe(summary)
    record_usage[key] = safe(usage)
    record_details[key] = safe(details)
    record_source[key] = source
    record_line[key] = line
    record_quality[key] = quality
    record_args[key] = args
    record_options[key] = options
    record_noargs[key] = noargs
  }
}

function catalog_function(name, source, line, is_bundle,
                          heading, i, text, previous, inline_value, category,
                          summary, usage, details, description_done, want_usage,
                          quality, is_internal, in_description, shdoc_found,
                          noargs, has_arg, has_option, arg_usage,
                          interface_conflict,
                          arg_text, arg_name, arg_type, arg_description,
                          arg_parts, arg_records, option_text, option_aliases,
                          option_description, option_parts, option_records,
                          part_count, j, k, tag_text, exit_code,
                          exit_description, optional_pattern,
                          legacy_section_pattern) {
  optional_pattern = "(^|[[:space:]])optional([[:space:]]|$)"
  legacy_section_pattern = \
    "^(Arguments|Options|Returns?|Examples?|Notes?|Behavior|" \
    "Requires?|Flags|Environment|Side Effects|Dependencies|Default):" \
    "[[:space:]]*"
  heading = 0
  for (i = 1; i <= pending_count; i++) {
    text = trim(comment_text(pending[i]))
    previous = i > 1 ? trim(comment_text(pending[i - 1])) : ""
    if (is_separator(previous) &&
        (text == name || text ~ ("^" name "[[:space:]]+[-—][[:space:]]+"))) {
      heading = i
    }
  }

  # Files in functions/ are explicit public bundles. Outside that directory,
  # only a shdoc block opts a function into the catalog.
  if (!heading && !is_bundle) {
    return
  }

  category = source
  if (category ~ /\/scripts\//) {
    sub(/^.*\/scripts\//, "", category)
    if (category ~ /\//) sub(/\/.*/, "", category)
  } else {
    sub(/^.*\//, "", category)
  }
  sub(/\.zsh$/, "", category)
  sub(/\.sh$/, "", category)
  if (heading) {
    # Parse the canonical shdoc annotations first.
    for (i = heading + 1; i <= pending_count; i++) {
      text = trim(comment_text(pending[i]))

      if (text ~ /^@internal([[:space:]]|$)/) {
        is_internal = 1
        continue
      }

      if (text ~ /^@description([[:space:]]|$)/) {
        in_description = 1
        shdoc_found = 1
        inline_value = text
        sub(/^@description[[:space:]]*/, "", inline_value)
        summary = append_text(summary, inline_value)
        continue
      }

      if (text ~ /^@[a-z]+([[:space:]]|$)/) in_description = 0

      if (text ~ /^@noargs[[:space:]]*$/) {
        noargs = 1
        continue
      }

      if (text ~ /^@arg[[:space:]]+/) {
        has_arg = 1
        arg_text = text
        sub(/^@arg[[:space:]]+/, "", arg_text)
        split(arg_text, arg_parts, /[[:space:]]+/)
        arg_name = arg_parts[1]
        arg_type = arg_parts[2]
        arg_description = arg_text
        sub(/^[^[:space:]]+[[:space:]]+/, "", arg_description)
        sub(/^[^[:space:]]+[[:space:]]*/, "", arg_description)
        arg_records = append_completion(arg_records, arg_name, arg_type, \
                                        arg_description)

        if (arg_name == "$@") {
          arg_usage = append_text(arg_usage, "[args...]")
        } else if (arg_name ~ /^\$[0-9]+$/) {
          if (tolower(arg_description) ~ optional_pattern) {
            arg_usage = append_text(arg_usage, "[" arg_name "]")
          } else {
            arg_usage = append_text(arg_usage, "<" arg_name ">")
          }
        }
        continue
      }

      if (text ~ /^@option[[:space:]]+/) {
        has_option = 1
        option_text = text
        sub(/^@option[[:space:]]+/, "", option_text)
        part_count = split(option_text, option_parts, /[[:space:]]+/)
        option_aliases = ""
        option_description = ""
        for (j = 1; j <= part_count; j++) {
          if (option_parts[j] == "|") continue
          if (option_parts[j] ~ /^-/) {
            option_aliases = option_aliases == "" ? option_parts[j] : \
              option_aliases "|" option_parts[j]
            continue
          }
          for (k = j; k <= part_count; k++) {
            option_description = append_text(option_description, \
                                             option_parts[k])
          }
          break
        }
        if (option_aliases != "") {
          option_records = append_completion(option_records, option_aliases, \
                                             "", option_description)
        }
        continue
      }

      if (text ~ /^@exitcode[[:space:]]+/) {
        tag_text = text
        sub(/^@exitcode[[:space:]]+/, "", tag_text)
        exit_code = tag_text
        sub(/[[:space:]].*$/, "", exit_code)
        exit_description = tag_text
        sub(/^[^[:space:]]+[[:space:]]*/, "", exit_description)
        details = append_text(details, "Exit " exit_code ": " exit_description)
        continue
      }

      if (text ~ /^@(stdin|stdout|stderr|set)[[:space:]]+/) {
        tag_text = text
        sub(/^@/, "", tag_text)
        details = append_text(details, tag_text)
        continue
      }

      if (in_description && text != "" && !is_separator(text)) {
        summary = append_text(summary, text)
      }
    }

    # Keep recognizing old blocks so --check can drive a gradual migration.
    if (!shdoc_found) {
      description_done = 0
      want_usage = 0
      for (i = heading + 1; i <= pending_count; i++) {
        text = trim(comment_text(pending[i]))

        if (text == "" || is_separator(text)) {
          if (summary != "") description_done = 1
          continue
        }
        if (text ~ /^@/) continue

        if (want_usage) {
          usage = text
          want_usage = 0
          continue
        }

        if (text ~ /^Usage:[[:space:]]*/) {
          inline_value = text
          sub(/^Usage:[[:space:]]*/, "", inline_value)
          if (inline_value == "") want_usage = 1
          else usage = inline_value
          description_done = 1
          continue
        }

        if (text ~ /^Category:[[:space:]]*/) {
          description_done = 1
          continue
        }

        if (text ~ legacy_section_pattern) {
          inline_value = text
          sub(/^[^:]+:[[:space:]]*/, "", inline_value)
          if (inline_value != "") details = append_text(details, text)
          description_done = 1
          continue
        }

        if (summary != "" && text ~ /^Behavior.*:$/) {
          details = append_text(details, text)
          description_done = 1
          continue
        }

        if (!description_done) summary = append_text(summary, text)
        else details = append_text(details, text)
      }
    }
  }

  if (is_internal) return

  category = tolower(category)
  sub(/^[0-9]+-/, "", category)
  gsub(/[^a-z0-9_.-]+/, "-", category)
  gsub(/^-+|-+$/, "", category)
  if (category == "") category = "other"

  if (shdoc_found) {
    interface_conflict = noargs && (has_arg || has_option)
    if (noargs) usage = name
    else {
      usage = name
      if (has_option) usage = usage " [options]"
      if (arg_usage != "") usage = usage " " arg_usage
    }

    if (interface_conflict) quality = "invalid"
    else if (summary != "" && \
             (noargs || has_arg || has_option)) quality = "standard"
    else quality = "legacy"
  } else if (summary == "") quality = "missing"
  else quality = "legacy"

  if (!is_bundle && !shdoc_found) return

  store_record(name, category, summary, usage, details, source, line, quality, \
               arg_records, option_records, noargs)
}

function reset_pending( i) {
  for (i = 1; i <= pending_count; i++) delete pending[i]
  pending_count = 0
}

FNR == 1 {
  reset_pending()
}

{
  raw = $0

  if (raw ~ /^[[:space:]]*#/ || raw ~ /^[[:space:]]*$/) {
    pending[++pending_count] = raw
    next
  }

  definition = raw
  sub(/^[[:space:]]*/, "", definition)
  if (definition ~ /^function[[:space:]]+/) {
    sub(/^function[[:space:]]+/, "", definition)
  }

  if (definition ~ \
      /^[A-Za-z][A-Za-z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/) {
    name = definition
    sub(/[[:space:]]*\(\)[[:space:]]*\{.*/, "", name)
    catalog_function(name, FILENAME, FNR, FILENAME ~ /\/functions\//)
  }

  reset_pending()
}

END {
  for (key in record_name) {
    if (output == "completions") {
      if (record_quality[key] != "standard") continue

      if (record_noargs[key]) {
        print record_name[key] sep \
              record_summary[key] sep \
              "noargs" sep "" sep "" sep ""
      }

      count = split(record_args[key], completion_items, completion_item_sep)
      for (item_index = 1; item_index <= count; item_index++) {
        if (completion_items[item_index] == "") continue
        split(completion_items[item_index], completion_fields, \
              completion_field_sep)
        print record_name[key] sep \
              record_summary[key] sep \
              "arg" sep \
              completion_fields[1] sep \
              completion_fields[2] sep \
              completion_fields[3]
      }

      count = split(record_options[key], completion_items, \
                    completion_item_sep)
      for (item_index = 1; item_index <= count; item_index++) {
        if (completion_items[item_index] == "") continue
        split(completion_items[item_index], completion_fields, \
              completion_field_sep)
        print record_name[key] sep \
              record_summary[key] sep \
              "option" sep \
              completion_fields[1] sep "" sep \
              completion_fields[3]
      }
      continue
    }

    print record_name[key] sep \
          record_category[key] sep \
          record_summary[key] sep \
          record_usage[key] sep \
          record_details[key] sep \
          safe(record_source[key]) sep \
          record_line[key] sep \
          record_quality[key]
  }
}
