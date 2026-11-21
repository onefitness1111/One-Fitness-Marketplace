package com.fitnessworkout.onefitness

import io.flutter.embedding.android.FlutterFragmentActivity

// FlutterFragmentActivity, not FlutterActivity: Stripe's native Payment Sheet
// is presented as an Android fragment, so it needs a FragmentActivity host.
// With plain FlutterActivity the sheet fails to launch at runtime.
// Health Connect's permission request uses that same fragment result API.
class MainActivity : FlutterFragmentActivity()
