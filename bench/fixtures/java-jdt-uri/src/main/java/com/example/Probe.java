package com.example;

import java.util.ArrayList;
import java.util.List;

// ADR-029 dogfood probe. Uses JDK classes only so jdtls returns
// `jdt://contents/...` URIs from goto_definition on the imports
// without needing Maven to resolve external deps. ArrayList is the
// goto-def target — goto on line 3, character 12-ish should yield
// jdt://contents/java.base/java.util/ArrayList.class or similar.
public class Probe {
  public static void main(String[] args) {
    List<String> items = new ArrayList<>();
    items.add("hello");
    items.add("world");
    for (String item : items) {
      System.out.println(item);
    }
  }
}
