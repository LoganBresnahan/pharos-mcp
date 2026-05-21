(ns com.example.probe
  "ADR-029 clojure-lsp probe — goto-def on `assoc` should land in the
   clojure jar's source via a `jar:file://` URI.")

(defn run []
  (let [m (assoc {} :a 1 :b 2)]
    (println m)))
