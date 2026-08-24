package app.roamsocket.android.ui.study

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.roamsocket.android.ui.theme.Palette

/**
 * Opens a saved deck: editable flashcards that persist on change.
 *
 * Ports [FlashcardDeckDetailView] from iOS `FlashcardDecksListView.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DeckDetailScreen(
    deckId: String,
    onBack: () -> Unit,
    deckStore: FlashcardDeckStore,
) {
    var deck by remember(deckId) { mutableStateOf<FlashcardDeck?>(null) }
    var showRename by remember { mutableStateOf(false) }
    var renameTitle by remember { mutableStateOf("") }

    LaunchedEffect(deckId) {
        deck = deckStore.deckById(deckId)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = deck?.title ?: "Deck",
                        color = Palette.TextPrimary,
                        maxLines = 1,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = "Back",
                            tint = Palette.TextPrimary,
                        )
                    }
                },
                actions = {
                    IconButton(onClick = {
                        renameTitle = deck?.title ?: ""
                        showRename = true
                    }) {
                        Icon(
                            imageVector = Icons.Outlined.CheckCircle,
                            contentDescription = "Rename deck",
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
        val currentDeck = deck
        if (currentDeck == null) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(24.dp),
            ) {
                Text(
                    text = "Deck not found",
                    style = MaterialTheme.typography.bodyLarge,
                    color = Palette.TextSecondary,
                )
            }
        } else {
            val cards = currentDeck.sortedCards

            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = 16.dp, vertical = 12.dp,
                ),
            ) {
                itemsIndexed(cards, key = { _, card -> card.id }) { index, card ->
                    var mutableCard by remember(card.id, card.updatedAt) {
                        mutableStateOf(card)
                    }

                    FlashcardCard(
                        index = index + 1,
                        question = mutableCard.question,
                        answer = mutableCard.answer,
                        reasoning = mutableCard.reasoning,
                        saveState = StudyCardSaveState.SAVED,
                        showSaveButton = false,
                        onQuestionChange = { newQ ->
                            mutableCard = mutableCard.copy(question = newQ)
                        },
                        onAnswerChange = { newA ->
                            mutableCard = mutableCard.copy(answer = newA)
                        },
                        onReasonChange = { newR ->
                            mutableCard = mutableCard.copy(reasoning = newR)
                        },
                        onSave = { },
                        onDelete = {
                            val updated = currentDeck.copy(
                                cards = currentDeck.cards.filter { it.id != card.id }.toMutableList(),
                            )
                            deckStore.upsertDeck(updated)
                            deck = updated
                        },
                    )

                    // Auto-save on any field change
                    LaunchedEffect(mutableCard.question, mutableCard.answer, mutableCard.reasoning) {
                        if (mutableCard != card) {
                            val updated = currentDeck.copy(
                                cards = currentDeck.cards.map {
                                    if (it.id == card.id) mutableCard else it
                                }.toMutableList(),
                            )
                            deckStore.upsertDeck(updated)
                            deck = updated
                        }
                    }
                }

                item {
                    Spacer(modifier = Modifier.height(24.dp))
                }
            }
        }
    }

    // Rename dialog.
    if (showRename) {
        AlertDialog(
            onDismissRequest = { showRename = false },
            title = { Text("Rename deck") },
            text = {
                OutlinedTextField(
                    value = renameTitle,
                    onValueChange = { renameTitle = it },
                    label = { Text("Deck name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    deckStore.renameDeck(deckId, renameTitle)
                    deck = deckStore.deckById(deckId)
                    showRename = false
                }) { Text("Save") }
            },
            dismissButton = {
                TextButton(onClick = { showRename = false }) { Text("Cancel") }
            },
        )
    }
}
