*** Begin Patch
*** Update File: Porch/Services/Connectors/WebSearch/WebSearchConnector.swift
@@
-    private var searchWebTool: ToolDefinition {
-        ToolDefinition(function: FunctionDefinitionBody(
-            name: "web_search",
-            description: "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for matching pages. Use this to find current information, look up facts, or relevant websites.",
-            parameters: .object([
-                "type": .string("object"),
-                "properties": .object([
-                    "query": .object([
-                        "type": .string("string"),
-                        "description": .string("The search query.")
-                    ]),
-                    "max_results": .object([
-                        "type": .string("integer"),
-                        "description": .string("Maximum number of results to return (default 8, max 15).")
-                    ])
-                ]),
-                "required": .array([.string("query")])
-            ])
-        ))
-    }
-
-    private var fetchPageTool: ToolDefinition {
-        ToolDefinition(function: FunctionDefinitionBody(
-            name: "web_fetch_page",
-            description: "Fetch and read the text content of a web page. Use this after web_search to read the full content of a specific result.",
-            parameters: .object([
-                "type": .string("object"),
-                "properties": .object([
-                    "url": .object([
-                        "type": .string("string"),
-                        "description": .string("The full URL of the page to fetch.")
-                    ]),
-                    "max_length": .object([
-                        "type": .string("integer"),
-                        "description": .string("Maximum character length of returned content (default 15000).")
-                    ])
-                ]),
-                "required": .array([.string("url")])
-            ])
-        ))
-    }
+    private var searchWebTool: ToolDefinition {
+        ToolDefinition(function: FunctionDefinitionBody(
+            name: "web_search",
+            description: "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for matching pages. Use this to find current information, look up facts, or relevant websites.",
+            parameters: .object([
+                "type": .string("object"),
+                "properties": .object([
+                    "query": .object([
+                        "type": .string("string"),
+                        "description": .string("The search query.")
+                    ]),
+                    "max_results": .object([
+                        "type": .string("integer"),
+                        "description": .string("Maximum number of results to return (default 8, max 15).")
+                    ])
+                ]),
+                "required": .array([.string("query")])
+            ])
+        ))
+    }
+
+    private var fetchPageTool: ToolDefinition {
+        ToolDefinition(function: FunctionDefinitionBody(
+            name: "web_fetch_page",
+            description: "Fetch and read the text content of a web page. Use this after web_search to read the full content of a specific result.",
+            parameters: .object([
+                "type": .string("object"),
+                "properties": .object([
+                    "url": .object([
+                        "type": .string("string"),
+                        "description": .string("The full URL of the page to fetch.")
+                    ]),
+                    "max_length": .object([
+                        "type": .string("integer"),
+                        "description": .string("Maximum character length of returned content (default 15000).")
+                    ])
+                ]),
+                "required": .array([.string("url")])
+            ])
+        ))
+    }
*** End Patch
