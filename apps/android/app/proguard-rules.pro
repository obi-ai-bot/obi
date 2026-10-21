# kotlinx.serialization keeps what it needs through its own rules; the character page calls back
# through this interface.
-keepclassmembers class com.deskree.oby.CharacterBridge { @android.webkit.JavascriptInterface <methods>; }
