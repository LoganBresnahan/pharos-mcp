package com.example;

import java.util.ArrayList;
import java.util.List;

// ADR-029 dogfood probe. Uses JDK classes only (java.util.ArrayList)
// so goto-def returns `jdt://contents/java.base/java.util/ArrayList.class`
// without needing any external Maven deps. Requires openjdk-21-source
// installed so jdtls can attach the JDK's src.zip.
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
