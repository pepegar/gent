(import core/tools :as tools)

(tools/register "read_file"
  {:description "Read the contents of a file at the given relative path. Use this when you need to see what's inside a file. Do not use this with directory names."
   :schema {:type "object"
            :properties {:path {:type "string"
                                :description "The relative path of a file to read"}}
            :required ["path"]}
   :function (fn [input]
               (def path (get input :path))
               (slurp path))})
