package com.fitnessworkout.onefitness

import android.app.Activity
import android.os.Bundle
import android.widget.ScrollView
import android.widget.TextView

// Health Connect's privacy link opens this screen. It has to say what is
// read, that nothing is written back, and that a coach sees it only after
// the client turns sharing on.
class HealthConnectPrivacyActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = TextView(this).apply {
            setPadding(48, 72, 48, 72)
            textSize = 16f
            setTextColor(0xFFFFFFFF.toInt())
            this.text = """
ONE Fitness reads health data from Health Connect only after you agree.

It can read steps, active calories, heart rate, resting heart rate, heart rate variability, sleep, workouts, weight, body fat, and lean mass. It does not write anything back.

Your coach sees those stats only if you turn on "Share health stats with my coach" in Log Progress. That switch starts off.

Your phone number, billing address, and legal name are not part of this data.

The full privacy policy is in the app under Profile Settings, Privacy Policy. You can also email info@onefitnessworkout.com.
            """.trimIndent()
        }
        val scroll = ScrollView(this)
        scroll.setBackgroundColor(0xFF000000.toInt())
        scroll.addView(text)
        setContentView(scroll)
    }
}
