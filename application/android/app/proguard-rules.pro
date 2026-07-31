-keep class com.tencent.** { *; }
-keep class com.tommy.rtmp.** { *; }
-dontwarn com.tencent.rtmp.ITXVodPlayListener$ITXVodAudioFrameDataListener
-dontwarn com.tencent.rtmp.TXVodDef$TXVodAudioFrameData
-dontwarn com.tencent.xmagic.XmagicApi$XmagicLightGameListener
-dontwarn com.tencent.xmagic.XmagicApi
-dontwarn com.tommy.rtmp.**

# Room 2.5 creates generated database implementations through Class.newInstance().
# AGP 9/R8 can otherwise remove their no-argument constructors.
-keep class * extends androidx.room.RoomDatabase {
    <init>();
}

# TencentEffect
-keep class com.tencent.xmagic.** { *;}
-keep class org.light.** { *;}
-keep class org.libpag.** { *;}
-keep class org.extra.** { *;}
-keep class com.gyailib.**{ *;}
-keep class com.tencent.cloud.iai.lib.** { *;}
-keep class com.tencent.beacon.** { *;}
-keep class com.tencent.qimei.** { *;}
-keep class androidx.exifinterface.** { *;}
-keep class com.tencent.effect.** { *;}
