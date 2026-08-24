package app.roamsocket.android.ui.study

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.School
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.roamsocket.android.ui.theme.Palette
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Study mode home: a big "Scan questions" entry plus the saved flashcard decks.
 *
 * Ports [FlashcardDecksListView] from iOS `FlashcardDecksListView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StudyScreen(
    onBack: () -> Unit,
    onOpenDeck: (String) -> Unit,
    onScan: () -> Unit,
    deckStore: FlashcardDeckStore,
) {
    var decks by remember { mutableStateOf(deckStore.sortedDecks) }

    LaunchedEffect(deckStore.decks.value) {
        deckStore.decks.collect { decks = it.sortedByDescending { d -> d.updatedAt } }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Study",
                        color = Palette.TextPrimary,
                    )
                },
                navigationIcon = {
                    androidx.compose.material3.IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                            tint = Palette.TextPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Palette.Background,
                ),
            )
        },
        containerColor = Palette.Background,
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Scan questions CTA
            item {
                ScanQuestionsCTA(
                    onClick = onScan,
                )
            }

            // Guided learning CTA (placeholder for now)
            item {
                GuidedLearningCTA(
                    onClick = { /* TODO: guided learning */ },
                )
            }

            // Decks section
            item {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Decks",
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextSecondary,
                )
            }

            if (decks.isEmpty()) {
                item {
                    EmptyDecksView()
                }
            } else {
                items(decks, key = { it.id }) { deck ->
                    DeckRow(
                        deck = deck,
                        onClick = { onOpenDeck(deck.id) },
                    )
                }
            }

            item {
                Spacer(modifier = Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun ScanQuestionsCTA(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(18.dp),
        color = Palette.Accent,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(18.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .background(Palette.OnAccent.copy(alpha = 0.14f), RoundedCornerShape(26.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.CameraAlt,
                    contentDescription = null,
                    tint = Palette.OnAccent,
                    modifier = Modifier.size(26.dp),
                )
            }

            Spacer(modifier = Modifier.width(14.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Scan questions",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.OnAccent,
                )
                Spacer(modifier = Modifier.height(3.dp))
                Text(
                    text = "Snap a page of questions to extract Q&A cards",
                    style = MaterialTheme.typography.bodySmall,
                    color = Palette.OnAccent.copy(alpha = 0.75f),
                )
            }

            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.OnAccent,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun GuidedLearningCTA(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(18.dp),
        color = Palette.Surface,
        border = BorderStroke(1.dp, Palette.Divider.copy(alpha = 0.8f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(18.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(52.dp)
                    .background(Palette.Accent.copy(alpha = 0.14f), RoundedCornerShape(26.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.School,
                    contentDescription = null,
                    tint = Palette.Accent,
                    modifier = Modifier.size(24.dp),
                )
            }

            Spacer(modifier = Modifier.width(14.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Guided learning",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                )
                Spacer(modifier = Modifier.height(3.dp))
                Text(
                    text = "A tutor teaches step by step, with check-ins and hints",
                    style = MaterialTheme.typography.bodySmall,
                    color = Palette.TextSecondary,
                )
            }

            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun EmptyDecksView() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = Icons.Outlined.Layers,
            contentDescription = null,
            tint = Palette.TextTertiary,
            modifier = Modifier.size(34.dp),
        )
        Text(
            text = "No decks yet",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = Palette.TextPrimary,
        )
        Text(
            text = "Scan a page of questions and save the cards — they'll appear here.",
            style = MaterialTheme.typography.bodyMedium,
            color = Palette.TextSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
    }
}

@Composable
private fun DeckRow(
    deck: FlashcardDeck,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(14.dp),
        color = Palette.Surface,
        border = BorderStroke(1.dp, Palette.Divider.copy(alpha = 0.7f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .background(Palette.Accent.copy(alpha = 0.14f), RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Layers,
                    contentDescription = null,
                    tint = Palette.Accent,
                    modifier = Modifier.size(18.dp),
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = deck.title.ifEmpty { "Untitled deck" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = Palette.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = "${deck.cards.size} card${if (deck.cards.size == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextSecondary,
                    )
                    Text(
                        text = "\u00b7",
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextTertiary,
                    )
                    Text(
                        text = relativeTime(deck.updatedAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = Palette.TextTertiary,
                    )
                }
            }

            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/** Simple relative time: just "today" / "yesterday" / "N days ago". */
private fun relativeTime(timestamp: Long): String {
    val diff = System.currentTimeMillis() - timestamp
    val days = (diff / (1000 * 60 * 60 * 24)).toInt()
    return when {
        days == 0 -> "today"
        days == 1 -> "yesterday"
        days < 7 -> "$days days ago"
        else -> SimpleDateFormat("MMM d", Locale.US).format(Date(timestamp))
    }
}
